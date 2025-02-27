/// Copyright 2015 Google Inc. All rights reserved.
///
/// Licensed under the Apache License, Version 2.0 (the "License");
/// you may not use this file except in compliance with the License.
/// You may obtain a copy of the License at
///
///    http://www.apache.org/licenses/LICENSE-2.0
///
///    Unless required by applicable law or agreed to in writing, software
///    distributed under the License is distributed on an "AS IS" BASIS,
///    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
///    See the License for the specific language governing permissions and
///    limitations under the License.

#import "Source/santasyncservice/SNTSyncRuleDownload.h"
#include "Source/santasyncservice/SNTPushNotificationsTracker.h"

#import <MOLXPCConnection/MOLXPCConnection.h>

#import "Source/common/SNTRule.h"
#import "Source/common/SNTSyncConstants.h"
#import "Source/common/SNTXPCControlInterface.h"
#import "Source/santasyncservice/SNTPushNotificationsTracker.h"
#import "Source/santasyncservice/SNTSyncLogging.h"
#import "Source/santasyncservice/SNTSyncState.h"

@implementation SNTSyncRuleDownload

- (NSURL *)stageURL {
  NSString *stageName = [@"ruledownload" stringByAppendingFormat:@"/%@", self.syncState.machineID];
  return [NSURL URLWithString:stageName relativeToURL:self.syncState.syncBaseURL];
}

- (BOOL)sync {
  // Grab the new rules from server
  NSArray<SNTRule *> *newRules = [self downloadNewRulesFromServer];
  if (!newRules) return NO;         // encountered a problem with the download
  if (!newRules.count) return YES;  // successfully completed request, but no new rules

  // Tell santad to add the new rules to the database.
  // Wait until finished or until 5 minutes pass.
  dispatch_semaphore_t sema = dispatch_semaphore_create(0);
  __block NSError *error;
  [[self.daemonConn remoteObjectProxy] databaseRuleAddRules:newRules
                                                 cleanSlate:self.syncState.cleanSync
                                                      reply:^(NSError *e) {
                                                        error = e;
                                                        dispatch_semaphore_signal(sema);
                                                      }];
  if (dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_SEC))) {
    SLOGE(@"Failed to add rule(s) to database: timeout sending rules to daemon");
    return NO;
  }

  if (error) {
    SLOGE(@"Failed to add rule(s) to database: %@", error.localizedDescription);
    SLOGD(@"Failure reason: %@", error.localizedFailureReason);
    return NO;
  }

  // Tell santad to record a successful rules sync and wait for it to finish.
  sema = dispatch_semaphore_create(0);
  [[self.daemonConn remoteObjectProxy] setRuleSyncLastSuccess:[NSDate date]
                                                        reply:^{
                                                          dispatch_semaphore_signal(sema);
                                                        }];
  dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

  SLOGI(@"Processed %lu rules", newRules.count);

  // Send out push notifications about any newly allowed binaries
  // that had been previously blocked by santad.
  [self announceUnblockingRules:newRules];
  return YES;
}

// Downloads new rules from server and converts them into SNTRule.
// Returns an array of all converted rules, or nil if there was a server problem.
// Note that rules from the server are filtered.  We only keep those whose rule_type
// is either BINARY or CERTIFICATE.  PACKAGE rules are dropped.
- (NSArray<SNTRule *> *)downloadNewRulesFromServer {
  NSMutableArray<SNTRule *> *newRules = [NSMutableArray array];
  NSString *cursor = nil;
  do {
    NSDictionary *requestDict = cursor ? @{kCursor : cursor} : @{};
    NSDictionary *response = [self performRequest:[self requestWithDictionary:requestDict]];

    if (![response isKindOfClass:[NSDictionary class]] ||
        ![response[kRules] isKindOfClass:[NSArray class]]) {
      return nil;
    }

    uint32_t count = 0;
    for (NSDictionary *ruleDict in response[kRules]) {
      SNTRule *rule = [[SNTRule alloc] initWithDictionary:ruleDict];
      if (rule) {
        [self processBundleNotificationsForRule:rule fromDictionary:ruleDict];
        [newRules addObject:rule];
        count++;
      }
    }
    SLOGI(@"Received %u rules", count);
    cursor = response[kCursor];
  } while (cursor);
  return newRules;
}

// Send out push notifications for allowed bundles/binaries whose rule download was preceded by
// an associated announcing FCM message.
- (void)announceUnblockingRules:(NSArray<SNTRule *> *)newRules {
  NSMutableArray *processed = [NSMutableArray array];
  SNTPushNotificationsTracker *tracker = [SNTPushNotificationsTracker tracker];
  [[tracker all]
    enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *notifier, BOOL *stop) {
      // Each notifier object is a dictionary with name and count keys. If the count has been
      // decremented to zero, then this means that we have downloaded all of the rules associated
      // with this SHA256 hash (which might be a bundle hash or a binary hash), in which case we are
      // OK to show a notification that the named bundle/binary can be run.
      NSNumber *remaining = notifier[kFileBundleBinaryCount];
      if (remaining && [remaining intValue] == 0) {
        [processed addObject:key];
        NSString *message = [NSString stringWithFormat:@"%@ can now be run", notifier[kFileName]];
        [[self.daemonConn remoteObjectProxy] postRuleSyncNotificationWithCustomMessage:message
                                                                                 reply:^{
                                                                                 }];
      }
    }];

  [tracker removeNotificationsForHashes:processed];
}

- (void)processBundleNotificationsForRule:(SNTRule *)rule fromDictionary:(NSDictionary *)dict {
  // Check rule for extra notification related info.
  if (rule.state == SNTRuleStateAllow || rule.state == SNTRuleStateAllowCompiler) {
    // primaryHash is the bundle hash if there was a bundle hash included in the rule, otherwise
    // it is simply the binary hash.
    NSString *primaryHash = dict[kFileBundleHash];
    if (primaryHash.length != 64) {
      primaryHash = rule.identifier;
    }

    // As we read in rules, we update the "remaining count" information. This count represents the
    // number of rules associated with the primary hash that still need to be downloaded and added.
    [[SNTPushNotificationsTracker tracker]
      decrementPendingRulesForHash:primaryHash
                    totalRuleCount:dict[kFileBundleBinaryCount]];
  }
}

@end
