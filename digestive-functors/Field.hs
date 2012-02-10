{-# LANGUAGE ExistentialQuantification, GADTs, OverloadedStrings, Rank2Types #-}
module Field where

import Control.Applicative (Applicative (..), (<$>))
import Control.Arrow (first)
import Control.Monad ((<=<))
import Data.List (findIndex)
import Data.Maybe (fromMaybe, listToMaybe, maybeToList)
import Data.Monoid (Monoid, mappend, mempty)

import GHC.Exts (IsString)
import Data.Text (Text)
import Text.Blaze (Html)
import qualified Data.Text as T

--------------------------------------------------------------------------------

data Result v a
    = Success a
    | Error v
    deriving (Show)

instance Functor (Result v) where
    fmap f (Success x) = Success (f x)
    fmap _ (Error x)   = Error x

instance Monoid v => Applicative (Result v) where
    pure x                  = Success x
    Error x   <*> Error y   = Error $ mappend x y
    Error x   <*> Success _ = Error x
    Success _ <*> Error y   = Error y
    Success x <*> Success y = Success (x y)

instance Monad (Result v) where
    return x          = Success x
    (Error x)   >>= _ = Error x
    (Success x) >>= f = f x

--------------------------------------------------------------------------------

data Field v a where
    Singleton :: a -> Field v a
    Text      :: Text -> Field v Text
    Choice    :: [(a, v)] -> Int -> Field v a
    Bool      :: Bool -> Field v Bool

instance Show (Field v a) where
    show (Singleton _) = "Singleton _"
    show (Text t)      = "Text " ++ show t
    show (Choice _ _)  = "Choice _ _"
    show (Bool b)      = "Bool " ++ show b

data SomeField v = forall a. SomeField (Field v a)

-- LONG LIVE GADTs!
printSomeField :: SomeField v -> IO ()
printSomeField (SomeField f) = case f of
    Text t -> putStrLn (T.unpack t)
    _      -> putStrLn "can't print and shit"

fieldDefaultText :: Field v a -> Maybe Text
fieldDefaultText (Text t) = Just t
fieldDefaultText _        = Nothing

--------------------------------------------------------------------------------

type Ref = Maybe Text
type Path = [Text]

data Form m v a where
    Pure :: Ref -> Field v a -> Form m v a
    App  :: Ref -> Form m v (b -> a) -> Form m v b -> Form m v a

    Map  :: (b -> m (Result v a)) -> Form m v b -> Form m v a

instance Monad m => Functor (Form m v) where
    fmap = transform . (return .) . (return .)

instance (Monad m, Monoid v) => Applicative (Form m v) where
    pure x  = Pure Nothing (Singleton x)
    x <*> y = App Nothing x y

instance Show (Form m v a) where
    show = unlines . showForm

data SomeForm m v = forall a. SomeForm (Form m v a)

instance Show (SomeForm m v) where
    show (SomeForm f) = show f

showForm :: Form m v a -> [String]
showForm form = case form of
    (Pure r x)  -> ["Pure (" ++ show r ++ ") (" ++ show x ++ ")"]
    (App r x y) -> concat
        [ ["App (" ++ show r ++ ")"]
        , map indent (showForm x)
        , map indent (showForm y)
        ]
    (Map _ x)   -> "Map _" : map indent (showForm x)
  where
    indent = ("  " ++)

children :: Form m v a -> [SomeForm m v]
children (Pure _ _)  = []
children (App _ x y) = [SomeForm x, SomeForm y]
children (Map _ x)   = children x

ref :: Text -> Form m v a -> Form m v a
ref r (Pure _ x)  = Pure (Just r) x
ref r (App _ x y) = App (Just r) x y
ref r (Map f x)   = Map f (ref r x)

(.:) :: Text -> Form m v a -> Form m v a
(.:) = ref
infixr 5 .:

getRef :: Form m v a -> Ref
getRef (Pure r _)  = r
getRef (App r _ _) = r
getRef (Map _ x)   = getRef x

transform :: Monad m => (a -> m (Result v b)) -> Form m v a -> Form m v b
transform f (Map g x) = flip Map x $ \y -> do
    y' <- g y
    case y' of
        Error errs  -> return $ Error errs
        Success y'' -> f y''
transform f x         = Map f x

lookupForm :: Path -> Form m v a -> [SomeForm m v]
lookupForm path = go path . SomeForm
  where
    go []       form            = [form]
    go (r : rs) (SomeForm form) = case getRef form of
        Just r'
            | r == r' && null rs -> [SomeForm form]
            | r == r'            -> children form >>= go rs
            | otherwise          -> []
        Nothing                  -> children form >>= go (r : rs)

toField :: Form m v a -> Maybe (SomeField v)
toField (Pure _ x) = Just (SomeField x)
toField (Map _ x)  = toField x
toField _          = Nothing

queryField :: Path
           -> Form m v a
           -> (forall b. Field v b -> Maybe c)
           -> Maybe c
queryField path form f = do
    SomeForm form'  <- listToMaybe $ lookupForm path form
    SomeField field <- toField form'
    f field

--------------------------------------------------------------------------------

ann :: Path -> Result v a -> Result [(Path, v)] a
ann _    (Success x) = Success x
ann path (Error x)   = Error [(path, x)]

--------------------------------------------------------------------------------

type Env m = Path -> m (Maybe Text)

eval :: Monad m => Env m -> Form m v a
     -> m (Result [(Path, v)] a, [(Path, Text)])
eval = eval' []

eval' :: Monad m => Path -> Env m -> Form m v a
      -> m (Result [(Path, v)] a, [(Path, Text)])

eval' context env form = case form of

    Pure (Just _) field -> do
        val <- env path
        let x = evalField val field
        return $ (pure x, maybeToList $ fmap ((,) path) val)

    App r x y -> do
        (x', inp1) <- eval' path env x
        (y', inp2) <- eval' path env y
        return (x' <*> y', inp1 ++ inp2)

    Map f x -> do
        (x', inp) <- eval' context env x
        case x' of
            Success x'' -> do
                x''' <- f x''  -- This is a bit ridiculous
                return (ann path x''', inp)
            Error errs  -> return (Error errs, inp)

  where
    path = context ++ maybeToList (getRef form)

evalField :: Maybe Text -> Field v a -> a
evalField _        (Singleton x) = x
evalField Nothing  (Text x)      = x
evalField (Just x) (Text _)      = x
evalField Nothing  (Choice ls x) = fst $ ls !! x
evalField (Just x) (Choice ls y) = fromMaybe (fst $ ls !! y) $ do
    -- Expects input in the form of @foo.bar.2@
    t <- listToMaybe $ reverse $ toPath x
    i <- readMaybe $ T.unpack t
    return $ fst $ ls !! i
evalField Nothing  (Bool x)      = x
evalField (Just x) (Bool _)      = x == "on"

--------------------------------------------------------------------------------

data View m v = forall a. View
    { viewForm   :: Form m v a
    , viewInput  :: [(Path, Text)]
    , viewErrors :: [(Path, v)]
    }

getForm :: Form m v a -> View m v
getForm form = View form [] []

postForm :: Monad m => Form m v a -> Env m -> m (Either (View m v) a)
postForm form env = eval env form >>= \(r, inp) -> return $ case r of
    Error errs -> Left $ View form inp errs
    Success x  -> Right x

--------------------------------------------------------------------------------

text :: Maybe Text -> Form m v Text
text def = Pure Nothing $ Text $ fromMaybe "" def

string :: Monad m => Maybe String -> Form m v String
string = fmap T.unpack . text . fmap T.pack

stringRead :: (IsString s, Monad m, Read a, Show a) => Maybe a -> Form m s a
stringRead = transform readTransform . string . fmap show
  where
    readTransform str = return $ case readMaybe str of
        Just x  -> return x
        Nothing -> Error "PBKAC"

choice :: Eq a => [(a, v)] -> Maybe a -> Form m v a
choice items def = Pure Nothing $ Choice items $ fromMaybe 0 $
    maybe Nothing (\d -> findIndex ((== d) . fst) items) def

bool :: Bool -> Form m v Bool
bool = Pure Nothing . Bool

readMaybe :: Read a => String -> Maybe a
readMaybe str = case readsPrec 1 str of
    [(x, "")] -> Just x
    _         -> Nothing

check :: Monad m => v -> (a -> Bool) -> Form m v a -> Form m v a
check err predicate form = transform f form
  where
    f x | predicate x = return (return x)
        | otherwise   = return (Error err)

--------------------------------------------------------------------------------

toPath :: Text -> Path
toPath = T.split (== '.')

fromPath :: Path -> Text
fromPath = T.intercalate "."
