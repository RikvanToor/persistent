{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE StandaloneDeriving #-}

-- | A MySQL backend for @persistent@.
module Database.Persist.MySQL
  ( withMySQLPool
  , withMySQLConn
  , createMySQLPool
  , module Database.Persist.Sql
  , MySQLConnectInfo
  , mkMySQLConnectInfo
  , setMySQLConnectInfoPort
  , setMySQLConnectInfoCharset
  , MySQLConf
  , mkMySQLConf
  , mockMigration
) where

import Control.Arrow
import Control.Monad (void)
import Control.Monad.Logger (MonadLogger, runNoLoggingT)
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT)
import Control.Monad.Trans.Reader (runReaderT)
import Control.Monad.Trans.Writer (runWriterT)
import Data.Monoid ((<>))
import Data.Aeson
import Data.Aeson.Types (modifyFailure)
import Data.Either (partitionEithers)
import Data.Fixed (Pico)
import Data.Function (on)
import Data.IORef
import Data.List (find, intercalate, sort, groupBy)
import Data.Pool (Pool)
import Data.Text (Text, pack)
import qualified Data.Text.IO as T
import Text.Read (readMaybe)
import System.Environment (getEnvironment)
import Data.Acquire (Acquire, mkAcquire, with)

import Data.Conduit
import qualified Data.ByteString.Lazy as BS
import qualified Data.Conduit.List as CL
import qualified Data.Map as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

import Database.Persist.Sql
import Database.Persist.Sql.Types.Internal (mkPersistBackend)
import Data.Int (Int64)

import qualified Database.MySQL.Base    as MySQL
import qualified System.IO.Streams      as Streams
import qualified Data.Time.Calendar     as Time
import qualified Data.Time.LocalTime    as Time
import qualified Data.ByteString.Char8  as BSC
import qualified Network.Socket         as NetworkSocket
import qualified Data.Word              as Word

import Control.Monad.Trans.Control (MonadBaseControl)
import Control.Monad.Trans.Resource (runResourceT)

-- | Create a MySQL connection pool and run the given action.
-- The pool is properly released after the action finishes using
-- it.  Note that you should not use the given 'ConnectionPool'
-- outside the action since it may be already been released.
withMySQLPool :: (MonadIO m, MonadLogger m, MonadBaseControl IO m, IsSqlBackend backend)
              => MySQLConnectInfo
              -- ^ Connection information.
              -> Int
              -- ^ Number of connections to be kept open in the pool.
              -> (Pool backend -> m a)
              -- ^ Action to be executed that uses the connection pool.
              -> m a
withMySQLPool ci = withSqlPool $ open' ci


-- | Create a MySQL connection pool.  Note that it's your
-- responsibility to properly close the connection pool when
-- unneeded.  Use 'withMySQLPool' for automatic resource control.
createMySQLPool :: (MonadBaseControl IO m, MonadIO m, MonadLogger m, IsSqlBackend backend)
                => MySQLConnectInfo
                -- ^ Connection information.
                -> Int
                -- ^ Number of connections to be kept open in the pool.
                -> m (Pool backend)
createMySQLPool ci = createSqlPool $ open' ci


-- | Same as 'withMySQLPool', but instead of opening a pool
-- of connections, only one connection is opened.
withMySQLConn :: (MonadBaseControl IO m, MonadIO m, MonadLogger m, IsSqlBackend backend)
              => MySQLConnectInfo
              -- ^ Connection information.
              -> (backend -> m a)
              -- ^ Action to be executed that uses the connection.
              -> m a
withMySQLConn = withSqlConn . open'


-- | Internal function that opens a connection to the MySQL
-- server.
open' :: (IsSqlBackend backend) => MySQLConnectInfo -> LogFunc -> IO backend
open' (MySQLConnectInfo ci) logFunc = do
    conn <- MySQL.connect ci
    autocommit' conn False -- disable autocommit!
    smap <- newIORef $ Map.empty
    return . mkPersistBackend $ SqlBackend
        { connPrepare    = prepare' conn
        , connStmtMap    = smap
        , connInsertSql  = insertSql'
        , connInsertManySql = Nothing
        , connUpsertSql = Nothing
        , connClose      = MySQL.close conn
        , connMigrateSql = migrate' ci
        , connBegin      = const $ begin' conn
        , connCommit     = const $ commit' conn
        , connRollback   = const $ rollback' conn
        , connEscapeName = pack . escapeDBName
        , connNoLimit    = "LIMIT 18446744073709551615"
        -- This noLimit is suggested by MySQL's own docs, see
        -- <http://dev.mysql.com/doc/refman/5.5/en/select.html>
        , connRDBMS      = "mysql"
        , connLimitOffset = decorateSQLWithLimitOffset "LIMIT 18446744073709551615"
        , connLogFunc    = logFunc
        , connMaxParams = Nothing
        }

-- | Set autocommit setting
autocommit' :: MySQL.MySQLConn -> Bool -> IO ()
autocommit' conn bool = void $ MySQL.execute conn "SET autocommit=?" [encodeBool bool]

-- | Start a transaction.
begin' :: MySQL.MySQLConn -> IO ()
begin' conn = void $ MySQL.execute_ conn "BEGIN"

-- | Commit the current transaction.
commit' :: MySQL.MySQLConn -> IO ()
commit' conn = void $ MySQL.execute_ conn "COMMIT"

-- | Rollback the current transaction.
rollback' :: MySQL.MySQLConn -> IO ()
rollback' conn = void $ MySQL.execute_ conn "ROLLBACK"

-- | Prepare a query.  We don't support prepared statements, but
-- we'll do some client-side preprocessing here.
prepare' :: MySQL.MySQLConn -> Text -> IO Statement
prepare' conn sql = do
    let query = MySQL.Query . BS.fromStrict . T.encodeUtf8 $ sql
    return Statement
        { stmtFinalize = return ()
        , stmtReset    = return ()
        , stmtExecute  = execute' conn query
        , stmtQuery    = withStmt' conn query
        }


-- | SQL code to be executed when inserting an entity.
insertSql' :: EntityDef -> [PersistValue] -> InsertSqlResult
insertSql' ent vals =
  let sql = pack $ concat
                [ "INSERT INTO "
                , escapeDBName $ entityDB ent
                , "("
                , intercalate "," $ map (escapeDBName . fieldDB) $ entityFields ent
                , ") VALUES("
                , intercalate "," (map (const "?") $ entityFields ent)
                , ")"
                ]
  in case entityPrimary ent of
       Just _ -> ISRManyKeys sql vals
       Nothing -> ISRInsertGet sql "SELECT LAST_INSERT_ID()"

-- | Execute an statement that doesn't return any results.
execute' :: MySQL.MySQLConn -> MySQL.Query -> [PersistValue] -> IO Int64
execute' conn query vals
  = fmap (fromIntegral . MySQL.okAffectedRows) $ MySQL.execute conn query (map P vals)

-- | query' allows arguments to be empty.
query'
  :: MySQL.QueryParam p => MySQL.MySQLConn -> MySQL.Query -> [p]
  -> IO ([MySQL.ColumnDef], Streams.InputStream [MySQL.MySQLValue])
query' conn qry [] = MySQL.query_ conn qry
query' conn qry ps = MySQL.query  conn qry ps

-- | Execute an statement that does return results.  The results
-- are fetched all at once and stored into memory.
withStmt' :: MonadIO m
          => MySQL.MySQLConn
          -> MySQL.Query
          -> [PersistValue]
          -> Acquire (Source m [PersistValue])
withStmt' conn query vals = do
    result <- mkAcquire createResult releaseResult
    return $ fetchRows result >>= CL.sourceList
  where
    createResult = return $ query' conn query (map P vals)
    releaseResult _ = return ()

    fetchRows result = liftIO $ do
      -- Find out the type of the columns
      (fields, is) <- result
      -- let getters = [ maybe PersistNull (getGetter f f . Just) | f <- fields]
      let getters = fmap getGetter fields
          convert = use getters
            where use (g:gs) (col:cols) =
                    let v  = g col
                        vs = use gs cols
                    in v `seq` vs `seq` (v:vs)
                  use _ _ = []

      -- Ready to go!
      let go acc = do
            row <- Streams.read is
            case row of
              Nothing  -> return (acc [])
              (Just r) -> let converted = convert r
                    in converted `seq` go (acc . (converted:))
      go id

-- | Encode a Haskell bool into a MySQLValue
encodeBool :: Bool -> MySQL.MySQLValue
encodeBool True = MySQL.MySQLInt8U 1
encodeBool False = MySQL.MySQLInt8U 0

-- | Decode a Numeric value into a PersistBool
decodeBool :: (Eq a, Num a) => a -> PersistValue
decodeBool 0 = PersistBool False
decodeBool _ = PersistBool True

-- | Decode a whole number into a PersistInt64
decodeInteger :: Integral a => a -> PersistValue
decodeInteger = PersistInt64 . fromIntegral

-- | Decode a decimal number into a PersistDouble
decodeDouble :: Real a => a -> PersistValue
decodeDouble = PersistDouble . realToFrac

-- | @newtype@ around 'PersistValue' that supports the
-- 'MySQL.Param' type class.
newtype P = P PersistValue

instance MySQL.QueryParam P where
  render (P (PersistText t))        = MySQL.putTextField $ MySQL.MySQLText t
  render (P (PersistByteString b))  = MySQL.putTextField $ MySQL.MySQLBytes b
  render (P (PersistInt64 i))       = MySQL.putTextField $ MySQL.MySQLInt64 i
  render (P (PersistDouble d))      = MySQL.putTextField $ MySQL.MySQLDouble d
  render (P (PersistBool b))        = MySQL.putTextField $ encodeBool b
  render (P (PersistDay d))         = MySQL.putTextField $ MySQL.MySQLDate d
  render (P (PersistTimeOfDay t))   = MySQL.putTextField $ MySQL.MySQLTime 0 t
  render (P (PersistUTCTime t))     = MySQL.putTextField . MySQL.MySQLTimeStamp $ Time.utcToLocalTime Time.utc t
  render (P (PersistNull))          = MySQL.putTextField $ MySQL.MySQLNull
  render (P (PersistList l))        = MySQL.putTextField . MySQL.MySQLText $ listToJSON l
  render (P (PersistMap m))         = MySQL.putTextField . MySQL.MySQLText $ mapToJSON m
  render (P (PersistRational r))    =
    MySQL.putTextField $ MySQL.MySQLDecimal $ read $ show (fromRational r :: Pico)
    -- FIXME: Too Ambigous, can not select precision without information about field
  render (P (PersistDbSpecific b))  = MySQL.putTextField $ MySQL.MySQLBytes b
  render (P (PersistObjectId _))    =
    error "Refusing to map a PersistObjectId to a MySQL value"

-- | @Getter a@ is a function that converts an incoming "MySQLValue"
-- into a data type @a@.
type Getter a = MySQL.MySQLValue -> a

-- | Get the corresponding @'Getter' 'PersistValue'@ depending on
-- the type of the column.
getGetter :: MySQL.ColumnDef -> Getter PersistValue
getGetter field = case (MySQL.columnLength field) of
  1 -> goBool
  _ -> go
  where
    -- Bool
    goBool (MySQL.MySQLInt8U v) = decodeBool v
    goBool (MySQL.MySQLInt8  v) = decodeBool v
    goBool _                    = PersistBool False
    -- Int64
    go (MySQL.MySQLInt8U  v) = decodeInteger v
    go (MySQL.MySQLInt8   v) = decodeInteger v
    go (MySQL.MySQLInt16U v) = decodeInteger v
    go (MySQL.MySQLInt16  v) = decodeInteger v
    go (MySQL.MySQLInt32U v) = decodeInteger v
    go (MySQL.MySQLInt32  v) = decodeInteger v
    go (MySQL.MySQLInt64U v) = decodeInteger v
    go (MySQL.MySQLInt64  v) = decodeInteger v
    go (MySQL.MySQLBit    v) = decodeInteger v
    -- Double
    -- TODO: FIX WARNING(S) AND TRY TO PROVIDE LEAST PRECISION LOSS
    go (MySQL.MySQLFloat    v) = decodeDouble v
    go (MySQL.MySQLDouble   v) = decodeDouble v
    go (MySQL.MySQLDecimal  v) = decodeDouble v
    -- ByteString and Text
    go (MySQL.MySQLBytes  v) = PersistByteString v
    go (MySQL.MySQLText   v) = PersistText v
    -- Time-related
    -- TODO: REMOVE ASSUMPTION THAT DATETIME and TIMESTAMP are in UTC
    go (MySQL.MySQLDateTime   v) = PersistUTCTime $ Time.localTimeToUTC Time.utc v
    go (MySQL.MySQLTimeStamp  v) = PersistUTCTime $ Time.localTimeToUTC Time.utc v
    go (MySQL.MySQLYear       v) = PersistDay (Time.fromGregorian (fromIntegral v) 1 1)
    go (MySQL.MySQLDate       v) = PersistDay v
    go (MySQL.MySQLTime _     v) = PersistTimeOfDay v
    -- Null
    go (MySQL.MySQLNull        ) = PersistNull
    -- Conversion using PersistDbSpecific
    go (MySQL.MySQLGeometry   v) = PersistDbSpecific v

----------------------------------------------------------------------


-- | Create the migration plan for the given 'PersistEntity'
-- @val@.
migrate' :: MySQL.ConnectInfo
         -> [EntityDef]
         -> (Text -> IO Statement)
         -> EntityDef
         -> IO (Either [Text] [(Bool, Text)])
migrate' connectInfo allDefs getter val = do
    let name = entityDB val
    (idClmn, old) <- getColumns connectInfo getter val
    let (newcols, udefs, fdefs) = mkColumns allDefs val
    let udspair = map udToPair udefs
    case (idClmn, old, partitionEithers old) of
      -- Nothing found, create everything
      ([], [], _) -> do
        let uniques = flip concatMap udspair $ \(uname, ucols) ->
                      [ AlterTable name $
                        AddUniqueConstraint uname $
                        map (findTypeAndMaxLen name) ucols ]
        let foreigns = do
              Column { cName=cname, cReference=Just (refTblName, _a) } <- newcols
              return $ AlterColumn name (refTblName, addReference allDefs (refName name cname) refTblName cname)

        let foreignsAlt = map (\fdef -> let (childfields, parentfields) = unzip (map (\((_,b),(_,d)) -> (b,d)) (foreignFields fdef))
                                        in AlterColumn name (foreignRefTableDBName fdef, AddReference (foreignRefTableDBName fdef) (foreignConstraintNameDBName fdef) childfields parentfields)) fdefs

        return $ Right $ map showAlterDb $ (addTable newcols val): uniques ++ foreigns ++ foreignsAlt
      -- No errors and something found, migrate
      (_, _, ([], old')) -> do
        let excludeForeignKeys (xs,ys) = (map (\c -> case cReference c of
                                                    Just (_,fk) -> case find (\f -> fk == foreignConstraintNameDBName f) fdefs of
                                                                     Just _ -> c { cReference = Nothing }
                                                                     Nothing -> c
                                                    Nothing -> c) xs,ys)
            (acs, ats) = getAlters allDefs name (newcols, udspair) $ excludeForeignKeys $ partitionEithers old'
            acs' = map (AlterColumn name) acs
            ats' = map (AlterTable  name) ats
        return $ Right $ map showAlterDb $ acs' ++ ats'
      -- Errors
      (_, _, (errs, _)) -> return $ Left errs

      where
        findTypeAndMaxLen tblName col = let (col', ty) = findTypeOfColumn allDefs tblName col
                                            (_, ml) = findMaxLenOfColumn allDefs tblName col
                                         in (col', ty, ml)

addTable :: [Column] -> EntityDef -> AlterDB
addTable cols entity = AddTable $ concat
           -- Lower case e: see Database.Persist.Sql.Migration
           [ "CREATe TABLE "
           , escapeDBName name
           , "("
           , idtxt
           , if null cols then [] else ","
           , intercalate "," $ map showColumn cols
           , ")"
           ]
    where
      name = entityDB entity
      idtxt = case entityPrimary entity of
                Just pdef -> concat [" PRIMARY KEY (", intercalate "," $ map (escapeDBName . fieldDB) $ compositeFields pdef, ")"]
                Nothing ->
                  let defText = defaultAttribute $ fieldAttrs $ entityId entity
                      sType = fieldSqlType $ entityId entity
                      autoIncrementText = case (sType, defText) of
                        (SqlInt64, Nothing) -> " AUTO_INCREMENT"
                        _ -> ""
                      maxlen = findMaxLenOfField (entityId entity)
                  in concat
                         [ escapeDBName $ fieldDB $ entityId entity
                         , " " <> showSqlType sType maxlen False
                         , " NOT NULL"
                         , autoIncrementText
                         , " PRIMARY KEY"
                         ]

-- | Find out the type of a column.
findTypeOfColumn :: [EntityDef] -> DBName -> DBName -> (DBName, FieldType)
findTypeOfColumn allDefs name col =
    maybe (error $ "Could not find type of column " ++
                   show col ++ " on table " ++ show name ++
                   " (allDefs = " ++ show allDefs ++ ")")
          ((,) col) $ do
            entDef   <- find ((== name) . entityDB) allDefs
            fieldDef <- find ((== col)  . fieldDB) (entityFields entDef)
            return (fieldType fieldDef)

-- | Find out the maxlen of a column (default to 200)
findMaxLenOfColumn :: [EntityDef] -> DBName -> DBName -> (DBName, Integer)
findMaxLenOfColumn allDefs name col =
   maybe (col, 200)
         ((,) col) $ do
           entDef     <- find ((== name) . entityDB) allDefs
           fieldDef   <- find ((== col) . fieldDB) (entityFields entDef)
           findMaxLenOfField fieldDef

-- | Find out the maxlen of a field
findMaxLenOfField :: FieldDef -> Maybe Integer
findMaxLenOfField fieldDef = do
    maxLenAttr <- find ((T.isPrefixOf "maxlen=") . T.toLower) (fieldAttrs fieldDef)
    readMaybe . T.unpack . T.drop 7 $ maxLenAttr

-- | Helper for 'AddReference' that finds out the which primary key columns to reference.
addReference :: [EntityDef] -> DBName -> DBName -> DBName -> AlterColumn
addReference allDefs fkeyname reftable cname = AddReference reftable fkeyname [cname] referencedColumns
    where
      referencedColumns = maybe (error $ "Could not find ID of entity " ++ show reftable
                                  ++ " (allDefs = " ++ show allDefs ++ ")")
                                id $ do
                                  entDef <- find ((== reftable) . entityDB) allDefs
                                  return $ map fieldDB $ entityKeyFields entDef

data AlterColumn = Change Column
                 | Add' Column
                 | Drop
                 | Default String
                 | NoDefault
                 | Update' String
                 -- | See the definition of the 'showAlter' function to see how these fields are used.
                 | AddReference
                    DBName -- Referenced table
                    DBName -- Foreign key name
                    [DBName] -- Referencing columns
                    [DBName] -- Referenced columns
                 | DropReference DBName

type AlterColumn' = (DBName, AlterColumn)

data AlterTable = AddUniqueConstraint DBName [(DBName, FieldType, Integer)]
                | DropUniqueConstraint DBName

data AlterDB = AddTable String
             | AlterColumn DBName AlterColumn'
             | AlterTable DBName AlterTable


udToPair :: UniqueDef -> (DBName, [DBName])
udToPair ud = (uniqueDBName ud, map snd $ uniqueFields ud)

----------------------------------------------------------------------


-- | Returns all of the 'Column'@s@ in the given table currently
-- in the database.
getColumns :: MySQL.ConnectInfo
           -> (Text -> IO Statement)
           -> EntityDef
           -> IO ( [Either Text (Either Column (DBName, [DBName]))] -- ID column
                 , [Either Text (Either Column (DBName, [DBName]))] -- everything else
                 )
getColumns connectInfo getter def = do
    -- Find out ID column.
    stmtIdClmn <- getter "SELECT COLUMN_NAME, \
                                 \IS_NULLABLE, \
                                 \DATA_TYPE, \
                                 \IF(IS_NULLABLE='YES', COALESCE(COLUMN_DEFAULT, 'NULL'), COLUMN_DEFAULT) \
                          \FROM INFORMATION_SCHEMA.COLUMNS \
                          \WHERE TABLE_SCHEMA = ? \
                            \AND TABLE_NAME   = ? \
                            \AND COLUMN_NAME  = ?"
    inter1 <- with (stmtQuery stmtIdClmn vals) ($$ CL.consume)
    ids <- runResourceT $ CL.sourceList inter1 $$ helperClmns -- avoid nested queries

    -- Find out all columns.
    stmtClmns <- getter "SELECT COLUMN_NAME, \
                               \IS_NULLABLE, \
                               \DATA_TYPE, \
                               \COLUMN_TYPE, \
                               \CHARACTER_MAXIMUM_LENGTH, \
                               \NUMERIC_PRECISION, \
                               \NUMERIC_SCALE, \
                               \IF(IS_NULLABLE='YES', COALESCE(COLUMN_DEFAULT, 'NULL'), COLUMN_DEFAULT) \
                        \FROM INFORMATION_SCHEMA.COLUMNS \
                        \WHERE TABLE_SCHEMA = ? \
                          \AND TABLE_NAME   = ? \
                          \AND COLUMN_NAME <> ?"
    inter2 <- with (stmtQuery stmtClmns vals) ($$ CL.consume)
    cs <- runResourceT $ CL.sourceList inter2 $$ helperClmns -- avoid nested queries

    -- Find out the constraints.
    stmtCntrs <- getter "SELECT CONSTRAINT_NAME, \
                               \COLUMN_NAME \
                        \FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE \
                        \WHERE TABLE_SCHEMA = ? \
                          \AND TABLE_NAME   = ? \
                          \AND COLUMN_NAME <> ? \
                          \AND CONSTRAINT_NAME <> 'PRIMARY' \
                          \AND REFERENCED_TABLE_SCHEMA IS NULL \
                        \ORDER BY CONSTRAINT_NAME, \
                                 \COLUMN_NAME"
    us <- with (stmtQuery stmtCntrs vals) ($$ helperCntrs)

    -- Return both
    return (ids, cs ++ us)
  where
    vals = [ PersistText $ T.decodeUtf8 $ MySQL.ciDatabase connectInfo
           , PersistText $ unDBName $ entityDB def
           , PersistText $ unDBName $ fieldDB $ entityId def ]

    helperClmns = CL.mapM getIt =$ CL.consume
        where
          getIt = fmap (either Left (Right . Left)) .
                  liftIO .
                  getColumn connectInfo getter (entityDB def)

    helperCntrs = do
      let check [ PersistText cntrName
                , PersistText clmnName] = return ( cntrName, clmnName )
          check other = fail $ "helperCntrs: unexpected " ++ show other
      rows <- mapM check =<< CL.consume
      return $ map (Right . Right . (DBName . fst . head &&& map (DBName . snd)))
             $ groupBy ((==) `on` fst) rows


-- | Get the information about a column in a table.
getColumn :: MySQL.ConnectInfo
          -> (Text -> IO Statement)
          -> DBName
          -> [PersistValue]
          -> IO (Either Text Column)
getColumn connectInfo getter tname [ PersistText cname
                                   , PersistText null_
                                   , PersistText dataType
                                   , PersistText colType
                                   , colMaxLen
                                   , colPrecision
                                   , colScale
                                   , default'] =
    fmap (either (Left . pack) Right) $
    runExceptT $ do
      -- Default value
      default_ <- case default' of
                    PersistNull   -> return Nothing
                    PersistText t -> return (Just t)
                    PersistByteString bs ->
                      case T.decodeUtf8' bs of
                        Left exc -> fail $ "Invalid default column: " ++
                                           show default' ++ " (error: " ++
                                           show exc ++ ")"
                        Right t  -> return (Just t)
                    _ -> fail $ "Invalid default column: " ++ show default'

      -- Foreign key (if any)
      stmt <- lift $ getter "SELECT REFERENCED_TABLE_NAME, \
                                   \CONSTRAINT_NAME, \
                                   \ORDINAL_POSITION \
                            \FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE \
                            \WHERE TABLE_SCHEMA = ? \
                              \AND TABLE_NAME   = ? \
                              \AND COLUMN_NAME  = ? \
                              \AND REFERENCED_TABLE_SCHEMA = ? \
                            \ORDER BY CONSTRAINT_NAME, \
                                     \COLUMN_NAME"
      let vars = [ PersistText $ T.decodeUtf8 $ MySQL.ciDatabase connectInfo
                 , PersistText $ unDBName $ tname
                 , PersistText cname
                 , PersistText $ T.decodeUtf8 $ MySQL.ciDatabase connectInfo ]
      cntrs <- with (stmtQuery stmt vars) ($$ CL.consume)
      ref <- case cntrs of
               [] -> return Nothing
               [[PersistText tab, PersistText ref, PersistInt64 pos]] ->
                   return $ if pos == 1 then Just (DBName tab, DBName ref) else Nothing
               _ -> fail "MySQL.getColumn/getRef: never here"

      let colMaxLen' = case colMaxLen of
            PersistInt64 l -> Just (fromIntegral l)
            _ -> Nothing
          ci = ColumnInfo
            { ciColumnType = colType
            , ciMaxLength = colMaxLen'
            , ciNumericPrecision = colPrecision
            , ciNumericScale = colScale
            }
      (typ, maxLen) <- parseColumnType dataType ci
      -- Okay!
      return Column
        { cName = DBName $ cname
        , cNull = null_ == "YES"
        , cSqlType = typ
        , cDefault = default_
        , cDefaultConstraintName = Nothing
        , cMaxLen = maxLen
        , cReference = ref
        }

getColumn _ _ _ x =
    return $ Left $ pack $ "Invalid result from INFORMATION_SCHEMA: " ++ show x

-- | Extra column information from MySQL schema
data ColumnInfo = ColumnInfo
  { ciColumnType :: Text
  , ciMaxLength :: Maybe Integer
  , ciNumericPrecision :: PersistValue
  , ciNumericScale :: PersistValue
  }

-- | Parse the type of column as returned by MySQL's
-- @INFORMATION_SCHEMA@ tables.
parseColumnType :: Monad m => Text -> ColumnInfo -> m (SqlType, Maybe Integer)
-- Ints
parseColumnType "tinyint" ci | ciColumnType ci == "tinyint(1)" = return (SqlBool, Nothing)
parseColumnType "int" ci | ciColumnType ci == "int(11)"        = return (SqlInt32, Nothing)
parseColumnType "bigint" ci | ciColumnType ci == "bigint(20)"  = return (SqlInt64, Nothing)
-- Double
parseColumnType "double" _                                     = return (SqlReal, Nothing)
parseColumnType "decimal" ci                                   =
  case (ciNumericPrecision ci, ciNumericScale ci) of
    (PersistInt64 p, PersistInt64 s) ->
      return (SqlNumeric (fromIntegral p) (fromIntegral s), Nothing)
    _ ->
      fail "missing DECIMAL precision in DB schema"
-- Text
parseColumnType "varchar" ci                                   = return (SqlString, ciMaxLength ci)
parseColumnType "text" _                                       = return (SqlString, Nothing)
-- ByteString
parseColumnType "varbinary" ci                                 = return (SqlBlob, ciMaxLength ci)
parseColumnType "blob" _                                       = return (SqlBlob, Nothing)
-- Time-related
parseColumnType "time" _                                       = return (SqlTime, Nothing)
parseColumnType "datetime" _                                   = return (SqlDayTime, Nothing)
parseColumnType "date" _                                       = return (SqlDay, Nothing)

parseColumnType _ ci                                           = return (SqlOther (ciColumnType ci), Nothing)


----------------------------------------------------------------------


-- | @getAlters allDefs tblName new old@ finds out what needs to
-- be changed from @old@ to become @new@.
getAlters :: [EntityDef]
          -> DBName
          -> ([Column], [(DBName, [DBName])])
          -> ([Column], [(DBName, [DBName])])
          -> ([AlterColumn'], [AlterTable])
getAlters allDefs tblName (c1, u1) (c2, u2) =
    (getAltersC c1 c2, getAltersU u1 u2)
  where
    getAltersC [] old = concatMap dropColumn old
    getAltersC (new:news) old =
        let (alters, old') = findAlters tblName allDefs new old
         in alters ++ getAltersC news old'

    dropColumn col =
      map ((,) (cName col)) $
        [DropReference n | Just (_, n) <- [cReference col]] ++
        [Drop]

    getAltersU [] old = map (DropUniqueConstraint . fst) old
    getAltersU ((name, cols):news) old =
        case lookup name old of
            Nothing ->
                AddUniqueConstraint name (map findTypeAndMaxLen cols) : getAltersU news old
            Just ocols ->
                let old' = filter (\(x, _) -> x /= name) old
                 in if sort cols == ocols
                        then getAltersU news old'
                        else  DropUniqueConstraint name
                            : AddUniqueConstraint name (map findTypeAndMaxLen cols)
                            : getAltersU news old'
        where
          findTypeAndMaxLen col = let (col', ty) = findTypeOfColumn allDefs tblName col
                                      (_, ml) = findMaxLenOfColumn allDefs tblName col
                                   in (col', ty, ml)


-- | @findAlters newColumn oldColumns@ finds out what needs to be
-- changed in the columns @oldColumns@ for @newColumn@ to be
-- supported.
findAlters :: DBName -> [EntityDef] -> Column -> [Column] -> ([AlterColumn'], [Column])
findAlters tblName allDefs col@(Column name isNull type_ def _defConstraintName maxLen ref) cols =
    case filter ((name ==) . cName) cols of
    -- new fkey that didnt exist before
        [] -> case ref of
               Nothing -> ([(name, Add' col)],[])
               Just (tname, _b) -> let cnstr = [addReference allDefs (refName tblName name) tname name]
                                  in (map ((,) tname) (Add' col : cnstr), cols)
        Column _ isNull' type_' def' _defConstraintName' maxLen' ref':_ ->
            let -- Foreign key
                refDrop = case (ref == ref', ref') of
                            (False, Just (_, cname)) -> [(name, DropReference cname)]
                            _ -> []
                refAdd  = case (ref == ref', ref) of
                            (False, Just (tname, _cname)) -> [(tname, addReference allDefs (refName tblName name) tname name)]
                            _ -> []
                -- Type and nullability
                modType | showSqlType type_ maxLen False `ciEquals` showSqlType type_' maxLen' False && isNull == isNull' = []
                        | otherwise = [(name, Change col)]
                -- Default value
                modDef | def == def' = []
                       | otherwise   = case def of
                                         Nothing -> [(name, NoDefault)]
                                         Just s -> [(name, Default $ T.unpack s)]
            in ( refDrop ++ modType ++ modDef ++ refAdd
               , filter ((name /=) . cName) cols )

  where
    ciEquals x y = T.toCaseFold (T.pack x) == T.toCaseFold (T.pack y)

----------------------------------------------------------------------


-- | Prints the part of a @CREATE TABLE@ statement about a given
-- column.
showColumn :: Column -> String
showColumn (Column n nu t def _defConstraintName maxLen ref) = concat
    [ escapeDBName n
    , " "
    , showSqlType t maxLen True
    , " "
    , if nu then "NULL" else "NOT NULL"
    , case def of
        Nothing -> ""
        Just s -> " DEFAULT " ++ T.unpack s
    , case ref of
        Nothing -> ""
        Just (s, _) -> " REFERENCES " ++ escapeDBName s
    ]


-- | Renders an 'SqlType' in MySQL's format.
showSqlType :: SqlType
            -> Maybe Integer -- ^ @maxlen@
            -> Bool -- ^ include character set information?
            -> String
showSqlType SqlBlob    Nothing    _     = "BLOB"
showSqlType SqlBlob    (Just i)   _     = "VARBINARY(" ++ show i ++ ")"
showSqlType SqlBool    _          _     = "TINYINT(1)"
showSqlType SqlDay     _          _     = "DATE"
showSqlType SqlDayTime _          _     = "DATETIME"
showSqlType SqlInt32   _          _     = "INT(11)"
showSqlType SqlInt64   _          _     = "BIGINT"
showSqlType SqlReal    _          _     = "DOUBLE"
showSqlType (SqlNumeric s prec) _ _     = "NUMERIC(" ++ show s ++ "," ++ show prec ++ ")"
showSqlType SqlString  Nothing    True  = "TEXT CHARACTER SET utf8"
showSqlType SqlString  Nothing    False = "TEXT"
showSqlType SqlString  (Just i)   True  = "VARCHAR(" ++ show i ++ ") CHARACTER SET utf8"
showSqlType SqlString  (Just i)   False = "VARCHAR(" ++ show i ++ ")"
showSqlType SqlTime    _          _     = "TIME"
showSqlType (SqlOther t) _        _     = T.unpack t

-- | Render an action that must be done on the database.
showAlterDb :: AlterDB -> (Bool, Text)
showAlterDb (AddTable s) = (False, pack s)
showAlterDb (AlterColumn t (c, ac)) =
    (isUnsafe ac, pack $ showAlter t (c, ac))
  where
    isUnsafe Drop = True
    isUnsafe _    = False
showAlterDb (AlterTable t at) = (False, pack $ showAlterTable t at)


-- | Render an action that must be done on a table.
showAlterTable :: DBName -> AlterTable -> String
showAlterTable table (AddUniqueConstraint cname cols) = concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " ADD CONSTRAINT "
    , escapeDBName cname
    , " UNIQUE("
    , intercalate "," $ map escapeDBName' cols
    , ")"
    ]
    where
      escapeDBName' (name, (FTTypeCon _ "Text"      ), maxlen) = escapeDBName name ++ "(" ++ show maxlen ++ ")"
      escapeDBName' (name, (FTTypeCon _ "String"    ), maxlen) = escapeDBName name ++ "(" ++ show maxlen ++ ")"
      escapeDBName' (name, (FTTypeCon _ "ByteString"), maxlen) = escapeDBName name ++ "(" ++ show maxlen ++ ")"
      escapeDBName' (name, _                         , _) = escapeDBName name
showAlterTable table (DropUniqueConstraint cname) = concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " DROP INDEX "
    , escapeDBName cname
    ]


-- | Render an action that must be done on a column.
showAlter :: DBName -> AlterColumn' -> String
showAlter table (oldName, Change (Column n nu t def defConstraintName maxLen _ref)) =
    concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " CHANGE "
    , escapeDBName oldName
    , " "
    , showColumn (Column n nu t def defConstraintName maxLen Nothing)
    ]
showAlter table (_, Add' col) =
    concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " ADD COLUMN "
    , showColumn col
    ]
showAlter table (n, Drop) =
    concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " DROP COLUMN "
    , escapeDBName n
    ]
showAlter table (n, Default s) =
    concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " ALTER COLUMN "
    , escapeDBName n
    , " SET DEFAULT "
    , s
    ]
showAlter table (n, NoDefault) =
    concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " ALTER COLUMN "
    , escapeDBName n
    , " DROP DEFAULT"
    ]
showAlter table (n, Update' s) =
    concat
    [ "UPDATE "
    , escapeDBName table
    , " SET "
    , escapeDBName n
    , "="
    , s
    , " WHERE "
    , escapeDBName n
    , " IS NULL"
    ]
showAlter table (_, AddReference reftable fkeyname t2 id2) = concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " ADD CONSTRAINT "
    , escapeDBName fkeyname
    , " FOREIGN KEY("
    , intercalate "," $ map escapeDBName t2
    , ") REFERENCES "
    , escapeDBName reftable
    , "("
    , intercalate "," $ map escapeDBName id2
    , ")"
    ]
showAlter table (_, DropReference cname) = concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " DROP FOREIGN KEY "
    , escapeDBName cname
    ]

refName :: DBName -> DBName -> DBName
refName (DBName table) (DBName column) =
    DBName $ T.concat [table, "_", column, "_fkey"]

----------------------------------------------------------------------


-- | Escape a database name to be included on a query.
escapeDBName :: DBName -> String
escapeDBName (DBName s) = '`' : go (T.unpack s)
    where
      go ('`':xs) = '`' : '`' : go xs
      go ( x :xs) =     x     : go xs
      go ""       = "`"

-- | Information required to connect to a MySQL database
-- using @persistent@'s generic facilities.  These values are the
-- same that are given to 'withMySQLPool'.
data MySQLConf = MySQLConf
    { myConnInfo :: MySQL.ConnectInfo
      -- ^ The connection information.
    , myPoolSize :: Int
      -- ^ How many connections should be held on the connection pool.
    } deriving Show

-- | Public constructor for @MySQLConf@.
mkMySQLConf
  :: MySQLConnectInfo  -- ^ The connection information.
  -> Int               -- ^ How many connections should be held on the connection pool.
  -> MySQLConf
mkMySQLConf (MySQLConnectInfo ci) = MySQLConf ci

-- | MySQL connection information.
newtype MySQLConnectInfo = MySQLConnectInfo MySQL.ConnectInfo
  deriving Show

-- | Public constructor for @MySQLConnectInfo@.
mkMySQLConnectInfo
  :: NetworkSocket.HostName -- ^ hostname
  -> BSC.ByteString          -- ^ username
  -> BSC.ByteString          -- ^ password
  -> BSC.ByteString          -- ^ database
  -> MySQLConnectInfo
mkMySQLConnectInfo host user pass db
  = MySQLConnectInfo   $ MySQL.defaultConnectInfo {
      MySQL.ciHost     = host
    , MySQL.ciUser     = user
    , MySQL.ciPassword = pass
    , MySQL.ciDatabase = db
  }

-- | Update port number for @MySQLConnectInfo@.
setMySQLConnectInfoPort :: NetworkSocket.PortNumber -> MySQLConnectInfo -> MySQLConnectInfo
setMySQLConnectInfoPort port (MySQLConnectInfo ci) = MySQLConnectInfo $ ci { MySQL.ciPort = port }

-- | Update character set for @MySQLConnectInfo@.
setMySQLConnectInfoCharset
  :: Word.Word8       -- ^ Numeric ID of collation. See https://dev.mysql.com/doc/refman/5.7/en/show-collation.html.
  -> MySQLConnectInfo -- ^ Reference connectInfo to perform update on
  -> MySQLConnectInfo
setMySQLConnectInfoCharset charset (MySQLConnectInfo ci) = MySQLConnectInfo $ ci { MySQL.ciCharset = charset }

-- TODO: submit a PR to mysql-haskell to add SHOW instance
deriving instance Show MySQL.ConnectInfo

instance FromJSON MySQLConf where
    parseJSON v = modifyFailure ("Persistent: error loading MySQL conf: " ++) $
      flip (withObject "MySQLConf") v $ \o -> do
        database <- o .: "database"
        host     <- o .: "host"
        port     <- o .: "port"
        user     <- o .: "user"
        password <- o .: "password"
        pool     <- o .: "poolsize"
        let ci = MySQL.defaultConnectInfo
                   { MySQL.ciHost     = host
                   , MySQL.ciPort     = read port
                   , MySQL.ciUser     = BSC.pack user
                   , MySQL.ciPassword = BSC.pack password
                   , MySQL.ciDatabase = BSC.pack database
                   }
        return $ MySQLConf ci pool

instance PersistConfig MySQLConf where
    type PersistConfigBackend MySQLConf = SqlPersistT

    type PersistConfigPool    MySQLConf = ConnectionPool

    createPoolConfig (MySQLConf cs size) = runNoLoggingT $ createMySQLPool (MySQLConnectInfo cs) size -- FIXME

    runPool _ = runSqlPool

    loadConfig = parseJSON

    applyEnv conf = do
        env <- getEnvironment
        let maybeEnv old var = maybe old id $ fmap BSC.pack $ lookup ("MYSQL_" ++ var) env
        return conf
          { myConnInfo =
              case myConnInfo conf of
                MySQL.ConnectInfo
                  { MySQL.ciHost     = host
                  , MySQL.ciPort     = port
                  , MySQL.ciUser     = user
                  , MySQL.ciPassword = password
                  , MySQL.ciDatabase = database
                  } -> (myConnInfo conf)
                         { MySQL.ciHost     = BSC.unpack $ maybeEnv (BSC.pack host) "HOST"
                         , MySQL.ciPort     = read (BSC.unpack $ maybeEnv (BSC.pack $ show port) "PORT")
                         , MySQL.ciUser     = maybeEnv user "USER"
                         , MySQL.ciPassword = maybeEnv password "PASSWORD"
                         , MySQL.ciDatabase = maybeEnv database "DATABASE"
                         }
          }

mockMigrate :: MySQL.ConnectInfo
         -> [EntityDef]
         -> (Text -> IO Statement)
         -> EntityDef
         -> IO (Either [Text] [(Bool, Text)])
mockMigrate _connectInfo allDefs _getter val = do
    let name = entityDB val
    let (newcols, udefs, fdefs) = mkColumns allDefs val
    let udspair = map udToPair udefs
    case () of
      -- Nothing found, create everything
      () -> do
        let uniques = flip concatMap udspair $ \(uname, ucols) ->
                      [ AlterTable name $
                        AddUniqueConstraint uname $
                        map (findTypeAndMaxLen name) ucols ]
        let foreigns = do
              Column { cName=cname, cReference=Just (refTblName, _a) } <- newcols
              return $ AlterColumn name (refTblName, addReference allDefs (refName name cname) refTblName cname)

        let foreignsAlt = map (\fdef -> let (childfields, parentfields) = unzip (map (\((_,b),(_,d)) -> (b,d)) (foreignFields fdef))
                                        in AlterColumn name (foreignRefTableDBName fdef, AddReference (foreignRefTableDBName fdef) (foreignConstraintNameDBName fdef) childfields parentfields)) fdefs

        return $ Right $ map showAlterDb $ (addTable newcols val): uniques ++ foreigns ++ foreignsAlt
    {- FIXME redundant, why is this here? The whole case expression is weird
      -- No errors and something found, migrate
      (_, _, ([], old')) -> do
        let excludeForeignKeys (xs,ys) = (map (\c -> case cReference c of
                                                    Just (_,fk) -> case find (\f -> fk == foreignConstraintNameDBName f) fdefs of
                                                                     Just _ -> c { cReference = Nothing }
                                                                     Nothing -> c
                                                    Nothing -> c) xs,ys)
            (acs, ats) = getAlters allDefs name (newcols, udspair) $ excludeForeignKeys $ partitionEithers old'
            acs' = map (AlterColumn name) acs
            ats' = map (AlterTable  name) ats
        return $ Right $ map showAlterDb $ acs' ++ ats'
      -- Errors
      (_, _, (errs, _)) -> return $ Left errs
    -}

      where
        findTypeAndMaxLen tblName col = let (col', ty) = findTypeOfColumn allDefs tblName col
                                            (_, ml) = findMaxLenOfColumn allDefs tblName col
                                         in (col', ty, ml)


-- | Mock a migration even when the database is not present.
-- This function will mock the migration for a database even when
-- the actual database isn't already present in the system.
mockMigration :: Migration -> IO ()
mockMigration mig = do
  smap <- newIORef $ Map.empty
  let sqlbackend = SqlBackend { connPrepare = \_ -> do
                                             return Statement
                                                        { stmtFinalize = return ()
                                                        , stmtReset = return ()
                                                        , stmtExecute = undefined
                                                        , stmtQuery = \_ -> return $ return ()
                                                        },
                             connInsertManySql = Nothing,
                             connInsertSql = undefined,
                             connStmtMap = smap,
                             connClose = undefined,
                             connMigrateSql = mockMigrate undefined,
                             connBegin = undefined,
                             connCommit = undefined,
                             connRollback = undefined,
                             connEscapeName = undefined,
                             connNoLimit = undefined,
                             connRDBMS = undefined,
                             connLimitOffset = undefined,
                             connLogFunc = undefined,
                             connUpsertSql = undefined,
                             connMaxParams = Nothing}
      result = runReaderT . runWriterT . runWriterT $ mig 
  resp <- result sqlbackend
  mapM_ T.putStrLn $ map snd $ snd resp