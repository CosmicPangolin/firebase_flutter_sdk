// File created by
// Lung Razvan <long1eu>
// on 21/09/2018

import 'dart:async';

import 'package:firebase_firestore/src/firebase/firestore/core/listent_sequence.dart';
import 'package:firebase_firestore/src/firebase/firestore/local/lru_delegate.dart';
import 'package:firebase_firestore/src/firebase/firestore/local/lru_garbage_collector.dart';
import 'package:firebase_firestore/src/firebase/firestore/local/memory_mutation_queue.dart';
import 'package:firebase_firestore/src/firebase/firestore/local/memory_persistence.dart';
import 'package:firebase_firestore/src/firebase/firestore/local/query_data.dart';
import 'package:firebase_firestore/src/firebase/firestore/local/reference_delegate.dart';
import 'package:firebase_firestore/src/firebase/firestore/local/reference_set.dart';
import 'package:firebase_firestore/src/firebase/firestore/model/document_key.dart';
import 'package:firebase_firestore/src/firebase/firestore/util/assert.dart';
import 'package:firebase_firestore/src/firebase/firestore/util/types.dart';

/// Provides LRU garbage collection functionality for [MemoryPersistence].
class MemoryLruReferenceDelegate implements ReferenceDelegate, LruDelegate {
  final MemoryPersistence persistence;
  Map<DocumentKey, int> orphanedSequenceNumbers;

  ListenSequence listenSequence;
  int _currentSequenceNumber;

  MemoryLruReferenceDelegate(this.persistence)
      : orphanedSequenceNumbers = {},
        listenSequence =
            ListenSequence(persistence.queryCache.highestListenSequenceNumber),
        _currentSequenceNumber = ListenSequence.INVALID {
    this.garbageCollector = new LruGarbageCollector(this);
  }

  @override
  ReferenceSet additionalReferences;

  @override
  LruGarbageCollector garbageCollector;

  @override
  int get targetCount => persistence.queryCache.targetCount;

  @override
  void onTransactionStarted() {
    Assert.hardAssert(_currentSequenceNumber == ListenSequence.INVALID,
        'Starting a transaction without committing the previous one');
    _currentSequenceNumber = listenSequence.next();
  }

  @override
  void onTransactionCommitted() {
    Assert.hardAssert(_currentSequenceNumber != ListenSequence.INVALID,
        'Committing a transaction without having started one');
    _currentSequenceNumber = ListenSequence.INVALID;
  }

  @override
  int get currentSequenceNumber {
    Assert.hardAssert(_currentSequenceNumber != ListenSequence.INVALID,
        'Attempting to get a sequence number outside of a transaction');
    return _currentSequenceNumber;
  }

  @override
  Future<void> forEachTarget(_, Consumer<QueryData> consumer) async {
    persistence.queryCache.forEachTarget(null, consumer);
  }

  @override
  Future<void> forEachOrphanedDocumentSequenceNumber(
      _, Consumer<int> consumer) async {
    for (int sequenceNumber in orphanedSequenceNumbers.values) {
      consumer(sequenceNumber);
    }
  }

  @override
  Future<int> removeQueries(_, int upperBound, Set<int> activeTargetIds) async {
    return persistence.queryCache.removeQueries(upperBound, activeTargetIds);
  }

  @override
  Future<int> removeOrphanedDocuments(_, int upperBound) async {
    return persistence.remoteDocumentCache
        .removeOrphanedDocuments(this, upperBound);
  }

  @override
  Future<void> removeMutationReference(_, DocumentKey key) async {
    orphanedSequenceNumbers[key] = currentSequenceNumber;
  }

  @override
  Future<void> removeTarget(_, QueryData queryData) async {
    final QueryData updated = queryData.copy(queryData.snapshotVersion,
        queryData.resumeToken, currentSequenceNumber);
    persistence.queryCache.updateQueryData(null, updated);
  }

  @override
  Future<void> addReference(_, DocumentKey key) async {
    orphanedSequenceNumbers[key] = currentSequenceNumber;
  }

  @override
  Future<void> removeReference(_, DocumentKey key) async {
    orphanedSequenceNumbers[key] = currentSequenceNumber;
  }

  @override
  Future<void> updateLimboDocument(_, DocumentKey key) async {
    orphanedSequenceNumbers[key] = currentSequenceNumber;
  }

  bool _mutationQueuesContainsKey(DocumentKey key) {
    for (MemoryMutationQueue mutationQueue in persistence.getMutationQueues()) {
      if (mutationQueue.containsKey(key)) {
        return true;
      }
    }
    return false;
  }

  Future<bool> isPinned(DocumentKey key, int upperBound) async {
    if (_mutationQueuesContainsKey(key)) {
      return true;
    }

    if (additionalReferences.containsKey(key)) {
      return true;
    }

    if (await persistence.queryCache.containsKey(null, key)) {
      return true;
    }

    int sequenceNumber = orphanedSequenceNumbers[key];
    return sequenceNumber != null && sequenceNumber > upperBound;
  }
}