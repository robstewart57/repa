{-# OPTIONS_HADDOCK hide #-}
{-# LANGUAGE ExplicitForAll, TypeOperators, FlexibleInstances, UndecidableInstances, BangPatterns #-}

module Data.Array.Repa.Base
	( Elt
	, Array(..)
	, deepSeqArray
	, singleton, toScalar
	, extent,    delay

	-- * Predicates
	, isManifest
	, isDelayed
	, isSegmented

	-- * Indexing
	, (!),  index
	, (!?), safeIndex
	, unsafeIndex

	-- * Conversions 
	, fromFunction	
	, fromVector, toVector
	, fromList,   toList
	
	-- * Forcing
	, force
	, forceBlockwise)
where
import Data.Array.Repa.Index
import Data.Array.Repa.Internals.Evaluate
import Data.Array.Repa.Shape			as S
import qualified Data.Vector.Unboxed		as V
import Data.Vector.Unboxed.Mutable		as VM
import Data.Vector.Unboxed			(Vector)
import System.IO.Unsafe	

stage	= "Data.Array.Repa.Array"

-- Array -----------------------------------------------------------------------------------------	
-- | Possibly delayed arrays.
data Array sh a
	= -- | An array represented as some concrete unboxed data.
	  Manifest  
		{ arrayExtent		:: !sh 
		, arrayVector		:: !(Vector a) }

          -- | An array represented as a function that computes each element.
	| Delayed 
		{ arrayExtent		:: !sh
		, arrayGetElem		:: !(sh -> a) }

	  -- | An delayed array broken into subranges.
	  --   INVARIANT: the ranges to not overlap.
	  --   INVARIANT: for a singleton array both elem fns return the same result.
	  --   TODO:      Try to store the ranges in a vector. We might need more instances.
	| Segmented 
		{ arrayExtent		:: !sh			-- extent of whole array.
		, arrayChoose		:: !(sh -> Bool)	-- fn to decide if we're in the first or second segment.
		, arrayBorderRanges	:: ![(sh, sh)] 
		, arrayBorderGetElem	:: !(sh -> a)		-- if we're in any of these ranges then use this fn.
		, arrayInnerRange	:: !(sh, sh)
		, arrayInnerGetElem	:: !(sh -> a) }		--   otherwise use this other one.

-- | Ensure an array's structure is fully evaluated.
--   This evaluates the extent and outer constructor, but does not `force` the elements.
--   TODO: Force the list in the Segmented version.
infixr 0 `deepSeqArray`
deepSeqArray 
	:: Shape sh
	=> Array sh a 
	-> b -> b

{-# INLINE deepSeqArray #-}
deepSeqArray arr x 
 = case arr of
	Manifest  sh uarr	-> sh `S.deepSeq` uarr `seq` x
	Delayed   sh _		-> sh `S.deepSeq` x
	Segmented sh _ _ _ _ _	-> sh `S.deepSeq` x


-- Predicates -------------------------------------------------------------------------------------
isManifest  :: Array sh a -> Bool
isManifest arr
 = case arr of
	Manifest{}	-> True
	_		-> False
	
isDelayed   :: Array sh a -> Bool
isDelayed arr
 = case arr of
	Delayed{}	-> True
	_		-> False

isSegmented :: Array sh a -> Bool
isSegmented arr
 = case arr of
	Segmented{}	-> True
	_		-> False


-- Singletons -------------------------------------------------------------------------------------
-- | Wrap a scalar into a singleton array.
singleton :: Elt a => a -> Array Z a
{-# INLINE singleton #-}
singleton 	= Delayed Z . const


-- | Take the scalar value from a singleton array.
toScalar :: Elt a => Array Z a -> a
{-# INLINE toScalar #-}
toScalar arr
 = case arr of
	Delayed   _ fn		-> fn Z
	Manifest  _ uarr	-> uarr V.! 0
	Segmented{}		-> arrayInnerGetElem arr Z
	

-- Projections ------------------------------------------------------------------------------------
-- | Take the extent of an array.
extent	:: Array sh a -> sh
{-# INLINE extent #-}
extent arr	= arrayExtent arr


-- | Unpack an array into delayed form.
delay 	:: (Shape sh, Elt a) 
	=> Array sh a 
	-> (sh, sh -> a)

{-# INLINE delay #-}	
delay arr
 = case arr of
	Delayed   sh fn	
	 -> (sh, fn)

	Manifest  sh vec
	 -> (sh, \ix -> vec V.! S.toIndex sh ix)

	Segmented{}
	 -> ( arrayExtent arr
	    , \ix -> if arrayChoose arr ix
			   then arrayBorderGetElem arr ix
			   else arrayInnerGetElem  arr ix)


-- Indexing ---------------------------------------------------------------------------------------

-- | Get an indexed element from an array.
--   This uses the same level of bounds checking as your Data.Vector installation.
--
(!), index
	:: forall sh a
	.  (Shape sh, Elt a)
	=> Array sh a
	-> sh 
	-> a

{-# INLINE (!) #-}
(!) arr ix = index arr ix

{-# INLINE index #-}
index arr ix
 = case arr of
	Delayed   _  fn
	 -> fn ix

	Manifest  sh vec
	 -> vec V.! (S.toIndex sh ix)

	Segmented{}
	 -> if arrayChoose arr ix
		then arrayBorderGetElem arr ix
		else arrayInnerGetElem  arr ix


-- | Get an indexed element from an array.
--   If the element is out of range then `Nothing`.
(!?), safeIndex
	:: forall sh a
	.  (Shape sh, Elt a)
	=> Array sh a
	-> sh 
	-> Maybe a

{-# INLINE (!?) #-}
(!?) arr ix = safeIndex arr ix

{-# INLINE safeIndex #-}
safeIndex arr ix
 = case arr of
	Delayed  _  fn
	 -> Just (fn ix)

	Manifest sh vec		
	 -> vec V.!? (S.toIndex sh ix)

	Segmented{}
	 -> Just (if arrayChoose arr ix
		  	then arrayBorderGetElem arr ix
			else arrayInnerGetElem  arr ix)


-- | Get an indexed element from an array, without bounds checking.
--
--   OBLIGATION: The index must be within the array. 
--
-- 	@inRange zeroDim (shape arr) ix == True@
-- 
unsafeIndex
	:: forall sh a
	.  (Shape sh, Elt a)
	=> Array sh a
	-> sh 
	-> a

{-# INLINE unsafeIndex #-}
unsafeIndex arr ix
 = case arr of
	Delayed  _  fn
	 -> fn ix

	Manifest sh uarr
	 -> uarr `V.unsafeIndex` (S.toIndex sh ix)

	Segmented{}
	 -> if arrayChoose arr ix
		then arrayBorderGetElem arr ix
		else arrayInnerGetElem  arr ix


-- Conversions ------------------------------------------------------------------------------------
-- | Create a `Delayed` array from a function.
fromFunction 
	:: Shape sh
	=> sh
	-> (sh -> a)
	-> Array sh a
	
{-# INLINE fromFunction #-}
fromFunction sh fnElems
	= sh `S.deepSeq` Delayed sh fnElems

-- | Create a `Manifest` array from an unboxed `U.Array`. 
--	The elements are in row-major order.
fromVector
	:: Shape sh
	=> sh
	-> Vector a
	-> Array sh a

{-# INLINE fromVector #-}
fromVector sh vec
	= sh   `S.deepSeq` 
	  vec `seq`
	  Manifest sh vec


-- | Convert an array to an unboxed `U.Array`, forcing it if required.
--	The elements come out in row-major order.
toVector
	:: (Shape sh, Elt a)
	=> Array sh a 
	-> Vector a
{-# INLINE toVector #-}
toVector arr
 = case force arr of
	Manifest _ vec	-> vec
	_		-> error $ stage ++ ".toVector: force failed"


-- Conversion -------------------------------------------------------------------------------------
-- | Convert a list to an array.
--	The length of the list must be exactly the `size` of the extent given, else `error`.
--
fromList
	:: (Shape sh, Elt a)
	=> sh
	-> [a]
	-> Array sh a
	
{-# INLINE fromList #-}
fromList sh xx
	| V.length vec /= S.size sh
	= error $ unlines
	 	[ stage ++ ".fromList: size of array shape does not match size of list"
		, "        size of shape = " ++ (show $ S.size sh) 	++ "\n"
		, "        size of list  = " ++ (show $ V.length vec) 	++ "\n" ]
	
	| otherwise
	= Manifest sh vec

	where	vec	= V.fromList xx
	
-- | Convert an array to a list.
toList 	:: (Shape sh, Elt a)
	=> Array sh a
	-> [a]

{-# INLINE toList #-}
toList arr
 = case force arr of
	Manifest _ vec	-> V.toList vec
	_		-> error $ stage ++ ".toList: force failed"


-- Forcing ----------------------------------------------------------------------------------------
-- | Force an array, so that it becomes `Manifest`.
--   The array is chunked up and evaluated in parallel.
force	:: (Shape sh, Elt a)
	=> Array sh a -> Array sh a
	
{-# INLINE force #-}
force arr
 = Manifest sh' vec'
 where	(sh', vec')
	 = case arr of
		Manifest sh vec
		 -> sh `S.deepSeq` vec `seq` (sh, vec)
		
		Delayed sh getElem
		 -> let vec	= unsafePerformIO
				$ do	mvec	<- VM.unsafeNew (S.size sh)
					fillVectorP mvec (getElem . fromIndex sh)
					V.unsafeFreeze mvec

		    in sh `S.deepSeq` vec `seq` (sh, vec)

		Segmented{}
		 -> let	sh	= arrayExtent arr
			vec	= unsafePerformIO
				$ do	mvec	<- VM.unsafeNew (S.size sh)
					fillVectorP mvec (index arr . fromIndex sh)
					V.unsafeFreeze mvec
					
		    in sh `S.deepSeq` vec `seq` (sh, vec)


-- | Force an array, so that it becomes `Manifest`.
--
--   The array is evaluated in parallel in a blockwise manner, where each block is
--   evaluated independently and in a separate thread. For delayed arrays which access
--   their source elements from the local neighbourhood, `forceBlockwise` should give
--   better cache performance than plain `force`.
--
forceBlockwise	
	:: Elt a
	=> Array DIM2 a -> Array DIM2 a
	
{-# INLINE forceBlockwise #-}
forceBlockwise arr
 = Manifest sh' vec'
 where	(sh', vec')
	 = case arr of
		Manifest sh vec
		 -> sh `S.deepSeq` vec `seq` (sh, vec)
		
		Delayed sh@(_ :. width) getElemFromDelayed
		 -> let vec	= newVectorBlockwiseP (getElemFromDelayed . fromIndex sh) (S.size sh) width
		    in	sh `S.deepSeq` vec `seq` (sh, vec)

		-- TODO: This needs the index to be DIM2 becase we call fillVectorBlock directly
		--       XXX no: Could fix this by looking at the total size of the array and determining 
		--               how many "pages" it has. Then call fillVectorBlock for each page.
		--       Need to skip pages at beginning and end, it's a range after all.
		Segmented sh@(_ :. width) 
			_inBorder
			_rngsBorder _getElemBorder
			(shInner1, shInner2)  getElemInner

		 -> shInner1 `S.deepSeq` shInner2 `S.deepSeq` sh `S.deepSeq`
	            let	(_ :. y0 :. x0)	= shInner1
			(_ :. y1 :. x1) = shInner2

			vec	= y0 `seq` x0 `seq` y1 `seq` x1 `seq`
				  unsafePerformIO
		 		$ do	!mvec	<- VM.unsafeNew (S.size sh)

					-- fill the inner segment
					fillVectorBlock mvec (getElemInner . fromIndex sh)
							width x0 y0 x1 y1

					-- TODO: fill border segs
					V.unsafeFreeze mvec
		    in	vec `seq` (sh, vec)


-- Elements ---------------------------------------------------------------------------------------
class V.Unbox a	=> Elt a

instance V.Unbox a => Elt a


