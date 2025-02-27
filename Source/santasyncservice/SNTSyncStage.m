/// Copyright 2016 Google Inc. All rights reserved.
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

#import "Source/santasyncservice/SNTSyncStage.h"
#include "Source/common/SNTCommonEnums.h"

#import <MOLXPCConnection/MOLXPCConnection.h>

#import "Source/common/SNTLogging.h"
#import "Source/common/SNTSyncConstants.h"
#import "Source/common/SNTXPCControlInterface.h"
#import "Source/santasyncservice/NSData+Zlib.h"
#import "Source/santasyncservice/SNTSyncLogging.h"
#import "Source/santasyncservice/SNTSyncState.h"

@interface SNTSyncStage ()

@property(readwrite) NSURLSession *urlSession;
@property(readwrite) SNTSyncState *syncState;
@property(readwrite) MOLXPCConnection *daemonConn;

@end

@implementation SNTSyncStage

- (nullable instancetype)initWithState:(nonnull SNTSyncState *)syncState {
  self = [super init];
  if (self) {
    _syncState = syncState;
    _urlSession = syncState.session;
    _daemonConn = syncState.daemonConn;
  }
  return self;
}

- (BOOL)sync {
  [self doesNotRecognizeSelector:_cmd];
  __builtin_unreachable();
}

- (NSString *)stageURL {
  [self doesNotRecognizeSelector:_cmd];
  __builtin_unreachable();
}

- (NSMutableURLRequest *)requestWithDictionary:(NSDictionary *)dictionary {
  NSData *requestBody = [NSData data];
  if (dictionary) {
    NSError *error;
    requestBody = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:&error];
    if (error) {
      SLOGD(@"Failed to encode JSON request: %@", error);
      return nil;
    }
  }

  NSMutableURLRequest *req = [[NSMutableURLRequest alloc] initWithURL:[self stageURL]];
  [req setHTTPMethod:@"POST"];
  [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  NSString *xsrfHeader = self.syncState.xsrfTokenHeader ?: kDefaultXSRFTokenHeader;
  [req setValue:self.syncState.xsrfToken forHTTPHeaderField:xsrfHeader];

  NSData *compressed;
  NSString *contentEncodingHeader;

  switch (self.syncState.contentEncoding) {
    case SNTSyncContentEncodingNone: break;
    case SNTSyncContentEncodingGzip:
      compressed = [requestBody gzipCompressed];
      contentEncodingHeader = @"gzip";
      break;
    case SNTSyncContentEncodingDeflate:
      compressed = [requestBody zlibCompressed];
      contentEncodingHeader = @"deflate";
      break;
    default:
      // This would be a programming error.
      LOGD(@"Unexpected value for content encoding %ld", self.syncState.contentEncoding);
  }

  if (compressed) {
    requestBody = compressed;
    [req setValue:contentEncodingHeader forHTTPHeaderField:@"Content-Encoding"];
  }

  [req setHTTPBody:requestBody];

  return req;
}

// Returns nil when there is a server connection issue.  For other errors, such as
// an empty response or an unparseable response, an empty dictionary is returned.
- (NSDictionary *)performRequest:(NSURLRequest *)request timeout:(NSTimeInterval)timeout {
  NSHTTPURLResponse *response;
  NSError *error;
  NSData *data;

  for (int attempt = 1; attempt < 6; ++attempt) {
    if (attempt > 1) {
      struct timespec ts = {.tv_sec = (attempt * 2)};
      nanosleep(&ts, NULL);
    }

    SLOGD(@"Performing request, attempt %d", attempt);
    data = [self performRequest:request timeout:timeout response:&response error:&error];
    if (response.statusCode == 200) break;

    // If the original request failed because of an auth error, attempt to get a new XSRF token and
    // try again. Unfortunately some servers cause NSURLSession to return 'client cert required' or
    // 'could not parse response' when a 403 occurs and SSL cert auth is enabled.
    if ((response.statusCode == 403 || error.code == NSURLErrorClientCertificateRequired ||
         error.code == NSURLErrorCannotParseResponse) &&
        [self fetchXSRFToken]) {
      NSMutableURLRequest *mutableRequest = [request mutableCopy];
      NSString *xsrfHeader = self.syncState.xsrfTokenHeader ?: kDefaultXSRFTokenHeader;
      [mutableRequest setValue:self.syncState.xsrfToken forHTTPHeaderField:xsrfHeader];
      request = mutableRequest;
      continue;
    }
  }

  // If the final attempt resulted in an error, log the error and return nil.
  if (response.statusCode != 200) {
    long code;
    NSString *errStr;
    if (response.statusCode > 0) {
      code = response.statusCode;
      errStr = [NSHTTPURLResponse localizedStringForStatusCode:response.statusCode];
    } else {
      code = (long)error.code;
      errStr = error.localizedDescription;
    }
    LOGE(@"HTTP Response: %ld %@", code, errStr);
    return nil;
  }

  if (data.length == 0) return @{};

  NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:[self stripXssi:data]
                                                       options:0
                                                         error:&error];
  if (error) SLOGD(@"Failed to decode JSON response: %@", error);

  return dict ?: @{};
}

- (NSDictionary *)performRequest:(NSURLRequest *)request {
  return [self performRequest:request timeout:30];
}

#pragma mark Internal Helpers

/**
  Perform a data request and capture the returned data, response and error objects.

  @param request The request to perform
  @param timeout The number of seconds to wait before cancelling the request
  @param response Return the response details
  @param error  Return the error details
  @returns data, The HTTP body of the response
*/
- (NSData *)performRequest:(NSURLRequest *)request
                   timeout:(NSTimeInterval)timeout
                  response:(out NSHTTPURLResponse **)response
                     error:(out NSError **)error {
  __block NSData *_data;
  __block NSHTTPURLResponse *_response;
  __block NSError *_error;

  dispatch_semaphore_t sema = dispatch_semaphore_create(0);
  NSURLSessionDataTask *task =
    [self.urlSession dataTaskWithRequest:request
                       completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                         if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                           _response = (NSHTTPURLResponse *)response;
                         }
                         _data = data;
                         _error = error;
                         dispatch_semaphore_signal(sema);
                       }];
  [task resume];

  if (dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * timeout))) {
    [task cancel];
  }

  if (response) *response = _response;
  if (error) *error = _error;
  return _data;
}

- (NSData *)stripXssi:(NSData *)data {
  static const char xssiOne[5] = {')', ']', '}', '\'', '\n'};
  static const char xssiTwo[3] = {']', ')', '}'};
  if (data.length >= sizeof(xssiOne) && strncmp(data.bytes, xssiOne, sizeof(xssiOne)) == 0) {
    return [data subdataWithRange:NSMakeRange(sizeof(xssiOne), data.length - sizeof(xssiOne))];
  }
  if (data.length >= sizeof(xssiTwo) && strncmp(data.bytes, xssiTwo, sizeof(xssiTwo)) == 0) {
    return [data subdataWithRange:NSMakeRange(sizeof(xssiTwo), data.length - sizeof(xssiTwo))];
  }
  return data;
}

- (BOOL)fetchXSRFToken {
  BOOL success = NO;
  if (!self.syncState.xsrfToken.length) {  // only fetch token once per session
    NSString *stageName = [@"xsrf" stringByAppendingFormat:@"/%@", self.syncState.machineID];
    NSURL *u = [NSURL URLWithString:stageName relativeToURL:self.syncState.syncBaseURL];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:u];
    [request setHTTPMethod:@"POST"];
    NSHTTPURLResponse *response;
    [self performRequest:request timeout:10 response:&response error:NULL];
    if (response.statusCode == 200) {
      NSDictionary *headers = [response allHeaderFields];
      self.syncState.xsrfToken = headers[kDefaultXSRFTokenHeader];
      NSString *xsrfTokenHeader = headers[kXSRFTokenHeader];
      self.syncState.xsrfTokenHeader = xsrfTokenHeader.length ? xsrfTokenHeader : nil;
      SLOGD(@"Retrieved new XSRF token");
      success = YES;
    } else {
      SLOGD(@"Failed to retrieve XSRF token");
    }
  };
  return success;
}

@end
