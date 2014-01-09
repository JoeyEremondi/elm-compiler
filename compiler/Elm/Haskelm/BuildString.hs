module Elm.Haskelm.BuildString where

import Control.Monad (foldM)
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import Text.Blaze.Html.Renderer.String (renderHtml)
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified System.Console.CmdArgs as CmdArgs
import System.Directory
import System.FilePath
import GHC.Conc

import Build.Dependencies (getSortedDependencies)
import qualified Generate.Html as Html
import qualified Metadata.Prelude as Prelude
import qualified Build.Utils as Utils
import qualified Build.Flags as Flag
import qualified Build.File as File
import qualified Elm.Internal.Paths as Path

import qualified System.IO.Temp as Temp



buildAll :: [(String, String)] -> String -> IO ()
buildAll modules rootFile = do
  --Make the temp directory to do the compilation
  cd <- getCurrentDirectory
  --TODO remove
  Temp.withTempDirectory cd ".elm_temp" (\dir -> 
    let
        flags = Flag.flags --TODo set default flags
        appendToOutput :: BS.ByteString -> FilePath -> IO BS.ByteString
        appendToOutput js filePath = do
          src <- BS.readFile (Utils.elmo flags filePath)
          return (BS.append src js)
          
        sources js = map Html.Link (Flag.scripts flags) ++ [ Html.Source js ]
          
        makeHtml js moduleName = ("html", BS.pack $ renderHtml html)
            where
              rtsPath = Maybe.fromMaybe Path.runtime (Flag.runtime flags)
              html = Html.generate rtsPath (takeBaseName rootFile) (sources js) moduleName "" 
    in do
       --TODO remove
       mapM (uncurry writeFile) modules
       setCurrentDirectory dir
       
       --Copy all the files to the temp folder
       mapM (uncurry writeFile) modules
       
       
       let noPrelude = Flag.no_prelude flags
       builtIns <- if noPrelude then return Map.empty else Prelude.interfaces

       files <- if Flag.make flags
                then getSortedDependencies (Flag.src_dir flags) builtIns rootFile
                else return [rootFile]

       (moduleName, interfaces) <-
           File.build flags (length files) builtIns "" files

       js <- foldM appendToOutput BS.empty files

       (extension, code) <- do
           putStr "Generating JavaScript ... "
           return ("js", js)
           

       let targetFile = Utils.buildPath flags rootFile extension
       createDirectoryIfMissing True (takeDirectory targetFile)
       BS.writeFile targetFile code
       putStrLn "Done"
       
       return code
       )
       
  

          