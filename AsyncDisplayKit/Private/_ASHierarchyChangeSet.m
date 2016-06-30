//
//  _ASHierarchyChangeSet.m
//  AsyncDisplayKit
//
//  Created by Adlai Holler on 9/29/15.
//
//  Copyright (c) 2014-present, Facebook, Inc.  All rights reserved.
//  This source code is licensed under the BSD-style license found in the
//  LICENSE file in the root directory of this source tree. An additional grant
//  of patent rights can be found in the PATENTS file in the same directory.
//

#import "_ASHierarchyChangeSet.h"
#import "ASInternalHelpers.h"
#import "NSIndexSet+ASHelpers.h"
#import "ASAssert.h"

NSString *NSStringFromASHierarchyChangeType(_ASHierarchyChangeType changeType)
{
  switch (changeType) {
    case _ASHierarchyChangeTypeInsert:
      return @"Insert";
    case _ASHierarchyChangeTypeDelete:
      return @"Delete";
    case _ASHierarchyChangeTypeReload:
      return @"Reload";
    default:
      return @"(invalid)";
  }
}

@interface _ASHierarchySectionChange ()
- (instancetype)initWithChangeType:(_ASHierarchyChangeType)changeType indexSet:(NSIndexSet *)indexSet animationOptions:(ASDataControllerAnimationOptions)animationOptions;

/**
 On return `changes` is sorted according to the change type with changes coalesced by animationOptions
 Assumes: `changes` is [_ASHierarchySectionChange] all with the same changeType
 */
+ (void)sortAndCoalesceChanges:(NSMutableArray *)changes;

/// Returns all the indexes from all the `indexSet`s of the given `_ASHierarchySectionChange` objects.
+ (NSMutableIndexSet *)allIndexesInSectionChanges:(NSArray *)changes;
@end

@interface _ASHierarchyItemChange ()
- (instancetype)initWithChangeType:(_ASHierarchyChangeType)changeType indexPaths:(NSArray *)indexPaths animationOptions:(ASDataControllerAnimationOptions)animationOptions presorted:(BOOL)presorted;

/**
 On return `changes` is sorted according to the change type with changes coalesced by animationOptions
 Assumes: `changes` is [_ASHierarchyItemChange] all with the same changeType
 */
+ (void)sortAndCoalesceChanges:(NSMutableArray *)changes ignoringChangesInSections:(NSIndexSet *)sections;
@end

@interface _ASHierarchyChangeSet ()

/// Original inserts + reloads. Nil until sort&coalesce.
@property (nonatomic, strong, readonly) NSMutableArray<_ASHierarchyItemChange *> *insertItemChanges;
@property (nonatomic, strong, readonly) NSMutableArray<_ASHierarchyItemChange *> *originalInsertItemChanges;
/// Original deletes + reloads. Nil until sort&coalesce.
@property (nonatomic, strong, readonly) NSMutableArray<_ASHierarchyItemChange *> *deleteItemChanges;
@property (nonatomic, strong, readonly) NSMutableArray<_ASHierarchyItemChange *> *originalDeleteItemChanges;
@property (nonatomic, strong, readonly) NSMutableArray<_ASHierarchyItemChange *> *reloadItemChanges;
/// Original inserts + reloads. Nil until sort&coalesce.
@property (nonatomic, strong, readonly) NSMutableArray<_ASHierarchySectionChange *> *insertSectionChanges;
@property (nonatomic, strong, readonly) NSMutableArray<_ASHierarchySectionChange *> *originalInsertSectionChanges;
/// Original deletes + reloads. Nil until sort&coalesce.
@property (nonatomic, strong, readonly) NSMutableArray<_ASHierarchySectionChange *> *deleteSectionChanges;
@property (nonatomic, strong, readonly) NSMutableArray<_ASHierarchySectionChange *> *originalDeleteSectionChanges;
@property (nonatomic, strong, readonly) NSMutableArray<_ASHierarchySectionChange *> *reloadSectionChanges;

@end

@implementation _ASHierarchyChangeSet {
  NSArray <NSNumber *> *_oldItemCounts;
  NSArray <NSNumber *> *_newItemCounts;
}

- (instancetype)init
{
  ASDisplayNodeFailAssert(@"_ASHierarchyChangeSet: -init is not supported. Call -initWithOldData:");
  return [self initWithOldData:@[]];
}

- (instancetype)initWithOldData:(NSArray<NSNumber *> *)oldItemCounts
{
  self = [super init];
  if (self) {
    _oldItemCounts = [oldItemCounts copy];
    
    _originalInsertItemChanges = [NSMutableArray new];
    _originalDeleteItemChanges = [NSMutableArray new];
    _reloadItemChanges = [NSMutableArray new];
    
    _originalInsertSectionChanges = [NSMutableArray new];
    _originalDeleteSectionChanges = [NSMutableArray new];
    _reloadSectionChanges = [NSMutableArray new];
  }
  return self;
}

#pragma mark External API

- (void)markCompletedWithNewItemCounts:(NSArray<NSNumber *> *)newItemCounts
{
  NSAssert(!_completed, @"Attempt to mark already-completed changeset as completed.");
  _completed = YES;
  _newItemCounts = newItemCounts;
  [self _sortAndCoalesceChangeArrays];
  [self _validateUpdate];
}

- (NSArray *)sectionChangesOfType:(_ASHierarchyChangeType)changeType
{
  [self _ensureCompleted];
  switch (changeType) {
    case _ASHierarchyChangeTypeInsert:
      return _insertSectionChanges;
    case _ASHierarchyChangeTypeReload:
      return _reloadSectionChanges;
    case _ASHierarchyChangeTypeDelete:
      return _deleteSectionChanges;
    default:
      NSAssert(NO, @"Request for section changes with invalid type: %lu", (long)changeType);
  }
}

- (NSArray *)itemChangesOfType:(_ASHierarchyChangeType)changeType
{
  [self _ensureCompleted];
  switch (changeType) {
    case _ASHierarchyChangeTypeInsert:
      return _insertItemChanges;
    case _ASHierarchyChangeTypeReload:
      return _reloadItemChanges;
    case _ASHierarchyChangeTypeDelete:
      return _deleteItemChanges;
    default:
      NSAssert(NO, @"Request for item changes with invalid type: %lu", (long)changeType);
  }
}

- (NSIndexSet *)indexesForItemChangesOfType:(_ASHierarchyChangeType)changeType inSection:(NSUInteger)section
{
  [self _ensureCompleted];
  NSMutableIndexSet *result = [NSMutableIndexSet indexSet];
  for (_ASHierarchyItemChange *change in [self itemChangesOfType:changeType]) {
    [result addIndexes:[NSIndexSet as_indexSetFromIndexPaths:change.indexPaths inSection:section]];
  }
  return result;
}

- (NSUInteger)newSectionForOldSection:(NSUInteger)oldSection
{
  ASDisplayNodeAssertNotNil(_deletedSections, @"Cannot call %@ before `markCompleted` returns.", NSStringFromSelector(_cmd));
  ASDisplayNodeAssertNotNil(_insertedSections, @"Cannot call %@ before `markCompleted` returns.", NSStringFromSelector(_cmd));
  [self _ensureCompleted];
  if ([_deletedSections containsIndex:oldSection]) {
    return NSNotFound;
  }

  NSUInteger newIndex = oldSection - [_deletedSections countOfIndexesInRange:NSMakeRange(0, oldSection)];
  newIndex += [_insertedSections as_indexChangeByInsertingItemsBelowIndex:newIndex];
  return newIndex;
}

- (void)deleteItems:(NSArray *)indexPaths animationOptions:(ASDataControllerAnimationOptions)options
{
  [self _ensureNotCompleted];
  _ASHierarchyItemChange *change = [[_ASHierarchyItemChange alloc] initWithChangeType:_ASHierarchyChangeTypeDelete indexPaths:indexPaths animationOptions:options presorted:NO];
  [_originalDeleteItemChanges addObject:change];
}

- (void)deleteSections:(NSIndexSet *)sections animationOptions:(ASDataControllerAnimationOptions)options
{
  [self _ensureNotCompleted];
  _ASHierarchySectionChange *change = [[_ASHierarchySectionChange alloc] initWithChangeType:_ASHierarchyChangeTypeDelete indexSet:sections animationOptions:options];
  [_originalDeleteSectionChanges addObject:change];
}

- (void)insertItems:(NSArray *)indexPaths animationOptions:(ASDataControllerAnimationOptions)options
{
  [self _ensureNotCompleted];
  _ASHierarchyItemChange *change = [[_ASHierarchyItemChange alloc] initWithChangeType:_ASHierarchyChangeTypeInsert indexPaths:indexPaths animationOptions:options presorted:NO];
  [_originalInsertItemChanges addObject:change];
}

- (void)insertSections:(NSIndexSet *)sections animationOptions:(ASDataControllerAnimationOptions)options
{
  [self _ensureNotCompleted];
  _ASHierarchySectionChange *change = [[_ASHierarchySectionChange alloc] initWithChangeType:_ASHierarchyChangeTypeInsert indexSet:sections animationOptions:options];
  [_originalInsertSectionChanges addObject:change];
}

- (void)reloadItems:(NSArray *)indexPaths animationOptions:(ASDataControllerAnimationOptions)options
{
  [self _ensureNotCompleted];
  _ASHierarchyItemChange *change = [[_ASHierarchyItemChange alloc] initWithChangeType:_ASHierarchyChangeTypeReload indexPaths:indexPaths animationOptions:options presorted:NO];
  [_reloadItemChanges addObject:change];
}

- (void)reloadSections:(NSIndexSet *)sections animationOptions:(ASDataControllerAnimationOptions)options
{
  [self _ensureNotCompleted];
  _ASHierarchySectionChange *change = [[_ASHierarchySectionChange alloc] initWithChangeType:_ASHierarchyChangeTypeReload indexSet:sections animationOptions:options];
  [_reloadSectionChanges addObject:change];
}

#pragma mark Private

- (BOOL)_ensureNotCompleted
{
  NSAssert(!_completed, @"Attempt to modify completed changeset %@", self);
  return !_completed;
}

- (BOOL)_ensureCompleted
{
  NSAssert(_completed, @"Attempt to process incomplete changeset %@", self);
  return _completed;
}

- (void)_sortAndCoalesceChangeArrays
{
  @autoreleasepool {

    // Split reloaded sections into [delete(oldIndex), insert(newIndex)]
    
    // Give these their "pre-reloads" values. Once we add in the reloads we'll re-process them.
    _deletedSections = [_ASHierarchySectionChange allIndexesInSectionChanges:_deleteSectionChanges];
    _insertedSections = [_ASHierarchySectionChange allIndexesInSectionChanges:_insertSectionChanges];
    _deleteSectionChanges = [_originalDeleteSectionChanges mutableCopy];
    _insertSectionChanges = [_originalInsertSectionChanges mutableCopy];
    
    for (_ASHierarchySectionChange *change in _reloadSectionChanges) {
      NSIndexSet *newSections = [change.indexSet as_indexesByMapping:^(NSUInteger idx) {
        NSUInteger newSec = [self newSectionForOldSection:idx];
        NSAssert(newSec != NSNotFound, @"Request to reload deleted section %lu", (unsigned long)idx);
        return newSec;
      }];
      
      _ASHierarchySectionChange *deleteChange = [[_ASHierarchySectionChange alloc] initWithChangeType:_ASHierarchyChangeTypeDelete indexSet:change.indexSet animationOptions:change.animationOptions];
      [_deleteSectionChanges addObject:deleteChange];
      
      _ASHierarchySectionChange *insertChange = [[_ASHierarchySectionChange alloc] initWithChangeType:_ASHierarchyChangeTypeInsert indexSet:newSections animationOptions:change.animationOptions];
      [_insertSectionChanges addObject:insertChange];
    }
    
    [_ASHierarchySectionChange sortAndCoalesceChanges:_deleteSectionChanges];
    [_ASHierarchySectionChange sortAndCoalesceChanges:_insertSectionChanges];
    _deletedSections = [_ASHierarchySectionChange allIndexesInSectionChanges:_deleteSectionChanges];
    _insertedSections = [_ASHierarchySectionChange allIndexesInSectionChanges:_insertSectionChanges];

    // Split reloaded items into [delete(oldIndexPath), insert(newIndexPath)]
    
    _deleteItemChanges = [_originalDeleteItemChanges mutableCopy];
    _insertItemChanges = [_originalInsertItemChanges mutableCopy];
    
    NSDictionary *insertedIndexPathsMap = [_ASHierarchyItemChange sectionToIndexSetMapFromChanges:_insertItemChanges ofType:_ASHierarchyChangeTypeInsert];
    NSDictionary *deletedIndexPathsMap = [_ASHierarchyItemChange sectionToIndexSetMapFromChanges:_deleteItemChanges ofType:_ASHierarchyChangeTypeDelete];
    
    for (_ASHierarchyItemChange *change in _reloadItemChanges) {
      NSAssert(change.changeType == _ASHierarchyChangeTypeReload, @"It must be a reload change to be in here");
      NSMutableArray *newIndexPaths = [NSMutableArray arrayWithCapacity:change.indexPaths.count];
      
      // Every indexPaths in the change need to update its section and/or row
      // depending on all the deletions and insertions
      // For reference, when batching reloads/deletes/inserts:
      // - delete/reload indexPaths that are passed in should all be their current indexPaths
      // - insert indexPaths that are passed in should all be their future indexPaths after deletions
      for (NSIndexPath *indexPath in change.indexPaths) {
        NSUInteger section = [self newSectionForOldSection:indexPath.section];
        NSUInteger item = indexPath.item;
        
        // Update row number based on deletions that are above the current row in the current section
        NSIndexSet *indicesDeletedInSection = deletedIndexPathsMap[@(indexPath.section)];
        item -= [indicesDeletedInSection countOfIndexesInRange:NSMakeRange(0, item)];
        // Update row number based on insertions that are above the current row in the future section
        NSIndexSet *indicesInsertedInSection = insertedIndexPathsMap[@(section)];
        item += [indicesInsertedInSection as_indexChangeByInsertingItemsBelowIndex:item];
        
        NSIndexPath *newIndexPath = [NSIndexPath indexPathForItem:item inSection:section];
        [newIndexPaths addObject:newIndexPath];
      }
      
      // All reload changes are translated into deletes and inserts
      // We delete the items that needs reload together with other deleted items, at their original index
      _ASHierarchyItemChange *deleteItemChangeFromReloadChange = [[_ASHierarchyItemChange alloc] initWithChangeType:_ASHierarchyChangeTypeDelete indexPaths:change.indexPaths animationOptions:change.animationOptions presorted:NO];
      [_deleteItemChanges addObject:deleteItemChangeFromReloadChange];
      // We insert the items that needs reload together with other inserted items, at their future index
      _ASHierarchyItemChange *insertItemChangeFromReloadChange = [[_ASHierarchyItemChange alloc] initWithChangeType:_ASHierarchyChangeTypeInsert indexPaths:newIndexPaths animationOptions:change.animationOptions presorted:NO];
      [_insertItemChanges addObject:insertItemChangeFromReloadChange];
    }
    _reloadItemChanges = nil;
    
    // Ignore item deletes in reloaded/deleted sections.
    [_ASHierarchyItemChange sortAndCoalesceChanges:_deleteItemChanges ignoringChangesInSections:_deletedSections];

    // Ignore item inserts in reloaded(new)/inserted sections.
    [_ASHierarchyItemChange sortAndCoalesceChanges:_insertItemChanges ignoringChangesInSections:_insertedSections];
  }
}

- (void)_validateUpdate
{
  NSIndexSet *allReloadedSections = [_ASHierarchySectionChange allIndexesInSectionChanges:_reloadSectionChanges];
  
  NSInteger newSectionCount = _newItemCounts.count;
  NSInteger oldSectionCount = _oldItemCounts.count;
  
  // Assert that the new section count is correct.
  ASDisplayNodeAssert(newSectionCount == oldSectionCount + _insertedSections.count - _deletedSections.count, @"Invalid number of sections. The number of sections after the update (%ld) must be equal to the number of sections before the update (%ld) plus or minus the number of sections inserted or deleted (%ld inserted, %ld deleted)", (long)newSectionCount, (long)oldSectionCount, (long)_insertedSections.count, (long)_deletedSections.count);
  
  // Assert that no invalid deletes/reloads happened.
  NSInteger invalidSectionDelete = NSNotFound;
  if (oldSectionCount == 0) {
    invalidSectionDelete = [_deletedSections firstIndex];
  } else {
    invalidSectionDelete = [_deletedSections indexGreaterThanIndex:oldSectionCount - 1];
  }
  ASDisplayNodeAssert(NSNotFound == invalidSectionDelete, @"Attempt to delete section %ld but there are only %ld sections before the update.", invalidSectionDelete, oldSectionCount);
  
  for (_ASHierarchyItemChange *change in _deleteItemChanges) {
    for (NSIndexPath *indexPath in change.indexPaths) {
      // Assert that item delete happened in a valid section.
      ASDisplayNodeAssert(indexPath.section < oldSectionCount, @"Attempt to delete item %ld from section %ld, but there are only %ld sections before the update.", (long)indexPath.item, (long)indexPath.section, (long)oldSectionCount);
      
      // Assert that item delete happened to a valid item.
      NSInteger oldItemCount = _oldItemCounts[indexPath.section].integerValue;
      ASDisplayNodeAssert(indexPath.item < oldItemCount, @"Attempt to delete item %ld from section %ld, which only contains %ld items before the update.", (long)indexPath.item, (long)indexPath.section, (long)oldItemCount);
    }
  }
  
  for (_ASHierarchyItemChange *change in _insertItemChanges) {
    for (NSIndexPath *indexPath in change.indexPaths) {
      // Assert that item insert happened in a valid section.
      ASDisplayNodeAssert(indexPath.section < newSectionCount, @"Attempt to insert item %ld into section %ld, but there are only %ld sections after the update.", (long)indexPath.item, (long)indexPath.section, (long)newSectionCount);
      
      // Assert that item delete happened to a valid item.
      NSInteger newItemCount = _newItemCounts[indexPath.section].integerValue;
      ASDisplayNodeAssert(indexPath.item < newItemCount, @"Attempt to insert item %ld into section %ld, which only contains %ld items after the update.", (long)indexPath.item, (long)indexPath.section, (long)newItemCount);
    }
  }
  
  // Assert that no sections were inserted out of bounds.
  NSInteger invalidSectionInsert = NSNotFound;
  if (newSectionCount == 0) {
    invalidSectionInsert = [_insertedSections firstIndex];
  } else {
    invalidSectionInsert = [_insertedSections indexGreaterThanIndex:newSectionCount - 1];
  }
  ASDisplayNodeAssert(NSNotFound == invalidSectionInsert, @"Attempt to insert section %ld but there are only %ld sections after the update.", (long)invalidSectionInsert, (long)newSectionCount);
  
  [_oldItemCounts enumerateObjectsUsingBlock:^(NSNumber * _Nonnull oldItemCountObj, NSUInteger oldSection, BOOL * _Nonnull stop) {
    NSUInteger oldItemCount = oldItemCountObj.unsignedIntegerValue;
    // If section was reloaded, ignore.
    if ([allReloadedSections containsIndex:oldSection]) {
      return;
    }
    // If section was deleted, ignore.
    NSUInteger newSection = [self newSectionForOldSection:oldSection];
    if (newSection == NSNotFound) {
      return;
    }
    
    NSIndexSet *insertedItems = [self indexesForItemChangesOfType:_ASHierarchyChangeTypeInsert inSection:newSection];
    NSIndexSet *deletedItems = [self indexesForItemChangesOfType:_ASHierarchyChangeTypeDelete inSection:newSection];
    NSIndexSet *reloadedItems = [self indexesForItemChangesOfType:_ASHierarchyChangeTypeReload inSection:newSection];
    
    // Assert that no reloaded items were deleted.
    NSUInteger deletedReloadedItem = [[deletedItems as_intersectionWithIndexes:reloadedItems] firstIndex];
    ASDisplayNodeAssert(deletedReloadedItem == NSNotFound, @"Attempt to delete and reload the same item at index path %@", [NSIndexPath indexPathForItem:deletedReloadedItem inSection:oldSection]);
    
    // Assert that the new item count is correct.
    NSUInteger newItemCount = _newItemCounts[newSection].unsignedIntegerValue;
    ASDisplayNodeAssert(newItemCount == oldItemCount + insertedItems.count - deletedItems.count, @"Invalid number of items in section %ld. The number of items after the update (%ld) must be equal to the number of items before the update (%ld) plus or minus the number of items inserted or deleted (%ld inserted, %ld deleted).", (long)oldSection, (long)newItemCount, (long)oldItemCount, (long)insertedItems.count, (long)deletedItems.count);
  }];
  
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<%@ %p: deletedSections=%@, insertedSections=%@, deletedItems=%@, insertedItems=%@>", NSStringFromClass(self.class), self, _deletedSections, _insertedSections, _deleteItemChanges, _insertItemChanges];
}


@end

@implementation _ASHierarchySectionChange

- (instancetype)initWithChangeType:(_ASHierarchyChangeType)changeType indexSet:(NSIndexSet *)indexSet animationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  self = [super init];
  if (self) {
    ASDisplayNodeAssert(indexSet.count > 0, @"Request to create _ASHierarchySectionChange with no sections!");
    _changeType = changeType;
    _indexSet = indexSet;
    _animationOptions = animationOptions;
  }
  return self;
}

+ (void)sortAndCoalesceChanges:(NSMutableArray *)changes
{
  if (changes.count < 1) {
    return;
  }
  
  _ASHierarchyChangeType type = [changes.firstObject changeType];
  
  // Lookup table [Int: AnimationOptions]
  NSMutableDictionary *animationOptions = [NSMutableDictionary new];
  
  // All changed indexes, sorted
  NSMutableIndexSet *allIndexes = [NSMutableIndexSet new];
  
  for (_ASHierarchySectionChange *change in changes) {
    [change.indexSet enumerateIndexesUsingBlock:^(NSUInteger idx, __unused BOOL *stop) {
      animationOptions[@(idx)] = @(change.animationOptions);
    }];
    [allIndexes addIndexes:change.indexSet];
  }
  
  // Create new changes by grouping sorted changes by animation option
  NSMutableArray *result = [NSMutableArray new];
  
  __block ASDataControllerAnimationOptions currentOptions = 0;
  NSMutableIndexSet *currentIndexes = [NSMutableIndexSet indexSet];

  NSEnumerationOptions options = type == _ASHierarchyChangeTypeDelete ? NSEnumerationReverse : kNilOptions;

  [allIndexes enumerateIndexesWithOptions:options usingBlock:^(NSUInteger idx, __unused BOOL * stop) {
    ASDataControllerAnimationOptions options = [animationOptions[@(idx)] integerValue];

    // End the previous group if needed.
    if (options != currentOptions && currentIndexes.count > 0) {
      _ASHierarchySectionChange *change = [[_ASHierarchySectionChange alloc] initWithChangeType:type indexSet:[currentIndexes copy] animationOptions:currentOptions];
      [result addObject:change];
      [currentIndexes removeAllIndexes];
    }

    // Start a new group if needed.
    if (currentIndexes.count == 0) {
      currentOptions = options;
    }

    [currentIndexes addIndex:idx];
  }];

  // Finish up the last group.
  if (currentIndexes.count > 0) {
    _ASHierarchySectionChange *change = [[_ASHierarchySectionChange alloc] initWithChangeType:type indexSet:[currentIndexes copy] animationOptions:currentOptions];
    [result addObject:change];
  }

  [changes setArray:result];
}

+ (NSMutableIndexSet *)allIndexesInSectionChanges:(NSArray<_ASHierarchySectionChange *> *)changes
{
  NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
  for (_ASHierarchySectionChange *change in changes) {
    [indexes addIndexes:change.indexSet];
  }
  return indexes;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<%@: anim=%lu, type=%@, indexes=%@>", NSStringFromClass(self.class), (unsigned long)_animationOptions, NSStringFromASHierarchyChangeType(_changeType), [self.indexSet as_smallDescription]];
}

@end

@implementation _ASHierarchyItemChange

- (instancetype)initWithChangeType:(_ASHierarchyChangeType)changeType indexPaths:(NSArray *)indexPaths animationOptions:(ASDataControllerAnimationOptions)animationOptions presorted:(BOOL)presorted
{
  self = [super init];
  if (self) {
    ASDisplayNodeAssert(indexPaths.count > 0, @"Request to create _ASHierarchyItemChange with no items!");
    _changeType = changeType;
    if (presorted) {
      _indexPaths = indexPaths;
    } else {
      SEL sorting = changeType == _ASHierarchyChangeTypeDelete ? @selector(asdk_inverseCompare:) : @selector(compare:);
      _indexPaths = [indexPaths sortedArrayUsingSelector:sorting];
    }
    _animationOptions = animationOptions;
  }
  return self;
}

// Create a mapping out of changes indexPaths to a {@section : [indexSet]} fashion
// e.g. changes: (0 - 0), (0 - 1), (2 - 5)
//  will become: {@0 : [0, 1], @2 : [5]}
+ (NSDictionary *)sectionToIndexSetMapFromChanges:(NSArray *)changes ofType:(_ASHierarchyChangeType)changeType
{
  NSMutableDictionary *sectionToIndexSetMap = [NSMutableDictionary dictionary];
  for (_ASHierarchyItemChange *change in changes) {
    NSAssert(change.changeType == changeType, @"The map we created must all be of the same changeType as of now");
    for (NSIndexPath *indexPath in change.indexPaths) {
      NSNumber *sectionKey = @(indexPath.section);
      NSMutableIndexSet *indexSet = sectionToIndexSetMap[sectionKey];
      if (indexSet) {
        [indexSet addIndex:indexPath.item];
      } else {
        indexSet = [NSMutableIndexSet indexSetWithIndex:indexPath.item];
        sectionToIndexSetMap[sectionKey] = indexSet;
      }
    }
  }
  return sectionToIndexSetMap;
}

+ (void)sortAndCoalesceChanges:(NSMutableArray *)changes ignoringChangesInSections:(NSIndexSet *)ignoredSections
{
  if (changes.count < 1) {
    return;
  }
  
  _ASHierarchyChangeType type = [changes.firstObject changeType];
  
  // Lookup table [NSIndexPath: AnimationOptions]
  NSMutableDictionary *animationOptions = [NSMutableDictionary new];
  
  // All changed index paths, sorted
  NSMutableArray *allIndexPaths = [NSMutableArray new];
  
  for (_ASHierarchyItemChange *change in changes) {
    for (NSIndexPath *indexPath in change.indexPaths) {
      if (![ignoredSections containsIndex:indexPath.section]) {
        animationOptions[indexPath] = @(change.animationOptions);
        [allIndexPaths addObject:indexPath];
      }
    }
  }
  
  SEL sorting = type == _ASHierarchyChangeTypeDelete ? @selector(asdk_inverseCompare:) : @selector(compare:);
  [allIndexPaths sortUsingSelector:sorting];

  // Create new changes by grouping sorted changes by animation option
  NSMutableArray *result = [NSMutableArray new];

  ASDataControllerAnimationOptions currentOptions = 0;
  NSMutableArray *currentIndexPaths = [NSMutableArray array];

  for (NSIndexPath *indexPath in allIndexPaths) {
    ASDataControllerAnimationOptions options = [animationOptions[indexPath] integerValue];

    // End the previous group if needed.
    if (options != currentOptions && currentIndexPaths.count > 0) {
      _ASHierarchyItemChange *change = [[_ASHierarchyItemChange alloc] initWithChangeType:type indexPaths:[currentIndexPaths copy] animationOptions:currentOptions presorted:YES];
      [result addObject:change];
      [currentIndexPaths removeAllObjects];
    }

    // Start a new group if needed.
    if (currentIndexPaths.count == 0) {
      currentOptions = options;
    }

    [currentIndexPaths addObject:indexPath];
  }

  // Finish up the last group.
  if (currentIndexPaths.count > 0) {
    _ASHierarchyItemChange *change = [[_ASHierarchyItemChange alloc] initWithChangeType:type indexPaths:[currentIndexPaths copy] animationOptions:currentOptions presorted:YES];
    [result addObject:change];
  }

  [changes setArray:result];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<%@: anim=%lu, type=%@, indexPaths=%@>", NSStringFromClass(self.class), (unsigned long)_animationOptions, NSStringFromASHierarchyChangeType(_changeType), self.indexPaths];
}

@end
