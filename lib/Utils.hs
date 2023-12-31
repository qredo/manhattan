{-# LANGUAGE BangPatterns      #-}

module Utils ( epochFromSlot
             , firstSlotFromEpoch
             , getCommitteeCountPerSlot
             , domainTypeValues
             , getRandaoMix
             , getSeed
             , computeShuffledIndex
             , isActiveValidator
             , getActiveValidatorIndices
             , shuffleList
            --  , computeProposerIndex
            --  , mySR
            --  , mySRB
             ) where

import Types
import Config
import Crypto.Hash.SHA256 ( hash )
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS ( index, take, append, pack, empty, length )
import Control.Exception ( assert )
import Data.Word ( Word64 )
import Data.Bits ( testBit, (.&.), shiftR )
import Serialize ( serializeWord64, unserializeByteStringToWord64 )
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as MV
import Control.Monad (when)

-- | Compute the Epoch a slot lived in
epochFromSlot :: Slot -> Epoch
epochFromSlot slot = slot `div` slotsPerEpoch

-- | Given a Epoch, returns its first slot
firstSlotFromEpoch :: Epoch -> Slot
firstSlotFromEpoch epoch = epoch * slotsPerEpoch

-- | Return the number of committees in each slot for the given epoch
getCommitteeCountPerSlot :: LightState -> Epoch -> IO Word64
getCommitteeCountPerSlot state epoch = do
    l <- (fromIntegral . MV.length) <$> getActiveValidatorIndices state epoch
    return $ max 1 $ min maxCommitteesPerSlot (l `div` slotsPerEpoch `div` targetCommitteeSize)

domainTypeValues :: DomainType -> ByteString
domainTypeValues DOMAIN_BEACON_PROPOSER     = BS.pack [0x00, 0x00, 0x00, 0x00]
domainTypeValues DOMAIN_BEACON_ATTESTER     = BS.pack [0x01, 0x00, 0x00, 0x00]
domainTypeValues DOMAIN_RANDAO              = BS.pack [0x02, 0x00, 0x00, 0x00]
domainTypeValues DOMAIN_DEPOSIT             = BS.pack [0x03, 0x00, 0x00, 0x00]
domainTypeValues DOMAIN_VOLUNTARY_EXIT      = BS.pack [0x04, 0x00, 0x00, 0x00]
domainTypeValues DOMAIN_SELECTION_PROOF     = BS.pack [0x05, 0x00, 0x00, 0x00]
domainTypeValues DOMAIN_AGGREGATE_AND_PROOF = BS.pack [0x06, 0x00, 0x00, 0x00]
domainTypeValues DOMAIN_APPLICATION_MASK    = BS.pack [0x00, 0x00, 0x00, 0x01]

-- | Return the seed for a given epoch
getSeed :: LightState -> Epoch -> DomainType -> ByteString
getSeed state epoch domain =
    let mix = getRandaoMix state (epoch + epochsPerHistoricalVector - minSeedLookAhead - 1)
        preimage = domainTypeValues domain `BS.append` serializeWord64 8 epoch `BS.append` mix
    in hash preimage

-- | Return the randao mix at a recent epoch
getRandaoMix :: LightState -> Epoch -> ByteString
getRandaoMix state epoch = let n = epoch `mod` epochsPerHistoricalVector
                           in mixes V.! (fromIntegral n)
    where mixes = randaoMixes state

-- | Returns the shuffled index corresponding to seed and indexCount
--   This is the spec-defined implementation, which shuffled only one index. This works, but this is very slow.
--   Real-life clients use the bulk version which shuffles an entire list at once, see @shuffleList@
computeShuffledIndex :: Word64 -> Word64 -> ByteString -> Word64
computeShuffledIndex = swapOrNotRound 0 shuffleRoundCount
    where swapOrNotRound :: Word64 -> Word64 -> Word64 -> Word64 -> ByteString -> Word64
          swapOrNotRound _ 0 index _ _ = index
          swapOrNotRound !currentRound !remainingRounds !index !indexCount_ !seed =
            let indexCount = assert (index < indexCount_) indexCount_
                pivot = unserializeByteStringToWord64 (BS.take 8 (hash (seed `BS.append` (serializeWord64 1 currentRound)))) `mod` indexCount
                flipP = (pivot + indexCount -  index) `mod` indexCount
                position = max index flipP
                posAsBytes = serializeWord64 4 (position `div` 256)
                source = hash (seed `BS.append` (serializeWord64 1 currentRound) `BS.append` posAsBytes)
                byte = BS.index source (fromIntegral ((position `mod` 256) `div` 8))
                newIndex = if (testBit byte (fromIntegral (position `mod` 8))) then flipP else index
            in swapOrNotRound (currentRound+1) (remainingRounds-1) newIndex indexCount_ seed

-- | Returns a shuffle list of indices. This is the efficient way of computing a shuffling for committee election (unless you are a light
--   client and are only interested in one index)
shuffleList :: MV.IOVector ValidatorIndex -> ByteString -> Int -> IO ()
shuffleList indices seed round_ = do
    -- putStrLn $ "Shuffling entire list"
    -- error $ "seed length: " ++ show (BS.length seed) -- gives: 32
    let listSize = fromIntegral $ MV.length indices
    when (listSize == 0) $ error "Can't shuffle empty list"
    goOneRound listSize round_
        where goOneRound :: Word64 -> Int -> IO ()
              goOneRound listSize !round = when (round >= 0) $ do
                let roundAsBytes = serializeWord64 1 (fromIntegral round)
                    pivot = unserializeByteStringToWord64 (BS.take 8 (hash (seed `BS.append` roundAsBytes))) `mod` listSize
                    mirror1 = (pivot + 2) `div` 2
                    mirror2 = (pivot + listSize) `div` 2
                    initialHashBytes = BS.empty
                swapOrNot listSize roundAsBytes pivot mirror1 mirror2 mirror1 initialHashBytes
                goOneRound listSize (round-1)
              swapOrNot :: Word64 -> ByteString -> Word64 ->  Word64 -> Word64 -> Word64 -> ByteString -> IO ()
              swapOrNot listSize roundAsBytes pivot mirror1 mirror2 !i !hashBytes = when (i <= mirror2) $ do
                let (flip_, bitIndex) = if i <= pivot
                                        -- then (pivot - i, i .&. 0xff)
                                        then (pivot - i, i `mod` 256)
                                        -- else (pivot + listSize - i, flip_ .&. 0xff)
                                        else (pivot + listSize - i, flip_ `mod` 256)
                    newHashBytes
                        | i <= pivot && (bitIndex == 0 || i == mirror1) = hash $ seed `BS.append` roundAsBytes `BS.append` serializeWord64 4 (i `div` 256)
                        | i > pivot && (bitIndex == 0xff || i == pivot + 1)          = hash $ seed `BS.append` roundAsBytes `BS.append` serializeWord64 4 (flip_ `div` 256)
                        | otherwise                                     = hashBytes
                    theByte = BS.index newHashBytes (fromIntegral (bitIndex `div` 8))
                    shouldSwap = testBit theByte (fromIntegral (bitIndex `mod` 8))
                    -- theBit = (theByte `shiftR` fromIntegral (bitIndex .&. 0x07)) .&. 1
                -- when (theBit /= 0) $ do
                when (shouldSwap) $ do
                    -- putStrLn $ "\t\t\t\tSwapping " ++ show i ++ " and " ++ show flip_
                    MV.swap indices (fromIntegral i) (fromIntegral flip_)
                swapOrNot listSize roundAsBytes pivot mirror1 mirror2 (i+1) newHashBytes


-- | Returns whether a validator is active for the given epoch
isActiveValidator :: Validator -> Epoch -> Bool
isActiveValidator validator epoch =
    activationEpoch validator <= epoch && epoch < exitEpoch validator

-- | Returns the list of active validators (their indices) for the given epoch
getActiveValidatorIndices :: LightState -> Epoch -> IO (MV.IOVector ValidatorIndex)
getActiveValidatorIndices state epoch = U.thaw $ flip U.imapMaybe (validators state) $ \i v ->
    if isActiveValidator v epoch then Just (fromIntegral i) else Nothing