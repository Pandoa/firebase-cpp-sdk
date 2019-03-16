// Copyright 2016 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "remote_config/src/include/firebase/remote_config.h"

#include <map>
#include <set>
#include <string>

#include "app/src/include/firebase/version.h"
#include "app/src/assert.h"
#include "app/src/log.h"
#include "app/src/reference_counted_future_impl.h"
#include "app/src/util_ios.h"
#include "remote_config/src/common.h"

#import "FIRRemoteConfig.h"

namespace firebase {
namespace remote_config {

DEFINE_FIREBASE_VERSION_STRING(FirebaseRemoteConfig);

// Global reference to the Firebase App.
static const ::firebase::App *g_app = nullptr;

// Global reference to the Remote Config instance.
static FIRRemoteConfig *g_remote_config_instance;

// Maps FIRRemoteConfigSource values to the ValueSource enumeration.
static const ValueSource kFirebaseRemoteConfigSourceToValueSourceMap[] = {
    kValueSourceRemoteValue,   // FIRRemoteConfigSourceRemote
    kValueSourceDefaultValue,  // FIRRemoteConfigSourceDefault
    kValueSourceStaticValue,   // FIRRemoteConfigSourceStatic
};
static_assert(FIRRemoteConfigSourceRemote == 0);
static_assert(FIRRemoteConfigSourceDefault == 1);
static_assert(FIRRemoteConfigSourceStatic == 2);

// Regular expressions used to determine if the config value is a "valid" bool.
// Written to match what is used internally by the Java implementation.
static NSString *true_pattern = @"^(1|true|t|yes|y|on)$";
static NSString *false_pattern = @"^(0|false|f|no|n|off|)$";

// If a fetch was throttled, this is set to the time when the throttling is
// finished, in milliseconds since epoch.
static NSNumber *g_throttled_end_time = @0;

// Saved default keys for each namespace.
static std::map<std::string, std::vector<std::string>> *g_default_keys = nullptr;
// Defaults uses "" to represent the root namespace.
static const char kRootNamespace[] = "";

InitResult Initialize(const App &app) {
  if (g_app) {
    LogWarning("Remote Config API already initialized");
    return kInitResultSuccess;
  }
  internal::RegisterTerminateOnDefaultAppDestroy();
  LogInfo("Remote Config API Initializing");
  FIREBASE_ASSERT(!g_remote_config_instance);
  g_app = &app;

  // Create the Remote Config instance.
  g_remote_config_instance = [FIRRemoteConfig remoteConfig];

  FutureData::Create();
  g_default_keys = new std::map<std::string, std::vector<std::string>>;

  LogInfo("Remote Config API Initialized");
  return kInitResultSuccess;
}

namespace internal {

bool IsInitialized() { return g_app != nullptr; }

}  // namespace internal


void Terminate() {
  if (g_app) {
    LogWarning("Remove Config API already shut down.");
    return;
  }
  internal::UnregisterTerminateOnDefaultAppDestroy();
  g_app = nullptr;
  g_remote_config_instance = nil;
  FutureData::Destroy();
  delete g_default_keys;
  g_default_keys = nullptr;
}

void SetDefaults(const ConfigKeyValue *defaults, size_t number_of_defaults) {
  SetDefaults(defaults, number_of_defaults, nullptr);
}

void SetDefaults(const ConfigKeyValue *defaults, size_t number_of_defaults,
                 const char *defaults_namespace) {
  FIREBASE_ASSERT_RETURN_VOID(internal::IsInitialized());
  NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
  const char* defaults_namespace_key = defaults_namespace ? defaults_namespace : kRootNamespace;
  std::vector<std::string> &defaults_vect =
      (*g_default_keys)[defaults_namespace_key];
  defaults_vect.clear();
  defaults_vect.reserve(number_of_defaults);
  for (size_t i = 0; i < number_of_defaults; ++i) {
    const char* key = defaults[i].key;
    dict[@(key)] = @(defaults[i].value);
    defaults_vect.push_back(key);
  }
  if (defaults_namespace) {
    [g_remote_config_instance setDefaults:dict namespace:@(defaults_namespace)];
  } else {
    [g_remote_config_instance setDefaults:dict];
  }
}

static id VariantToNSObject(const Variant &variant) {
  if (variant.is_int64()) {
    return [NSNumber numberWithLongLong:variant.int64_value()];
  } else if (variant.is_bool()) {
    return [NSNumber numberWithBool:variant.bool_value() ? YES : NO];
  } else if (variant.is_double()) {
    return [NSNumber numberWithDouble:variant.double_value()];
  } else if (variant.is_string()) {
    return @(variant.string_value());
  } else if (variant.is_blob()) {
    return [NSData dataWithBytes:variant.blob_data() length:variant.blob_size()];
  } else {
    return nil;
  }
}

void SetDefaults(const ConfigKeyValueVariant *defaults, size_t number_of_defaults) {
  SetDefaults(defaults, number_of_defaults, nullptr);
}

void SetDefaults(const ConfigKeyValueVariant *defaults, size_t number_of_defaults,
                 const char *defaults_namespace) {
  FIREBASE_ASSERT_RETURN_VOID(internal::IsInitialized());
  NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
  const char* defaults_namespace_key = defaults_namespace ? defaults_namespace : kRootNamespace;
  std::vector<std::string> &defaults_vect =
      (*g_default_keys)[defaults_namespace_key];
  defaults_vect.clear();
  defaults_vect.reserve(number_of_defaults);
  for (size_t i = 0; i < number_of_defaults; ++i) {
    const char* key = defaults[i].key;
    id value = VariantToNSObject(defaults[i].value);
    if (value) {
      dict[@(key)] = value;
      defaults_vect.push_back(key);
    } else {
      LogError("Remote Config: Invalid Variant type for SetDefaults() key %s", key);
    }
  }
  if (defaults_namespace) {
    [g_remote_config_instance setDefaults:dict namespace:@(defaults_namespace)];
  } else {
    [g_remote_config_instance setDefaults:dict];
  }
}

std::string GetConfigSetting(ConfigSetting setting) {
  FIREBASE_ASSERT_RETURN(std::string(), internal::IsInitialized());
  switch (setting) {
  case kConfigSettingDeveloperMode:
    return g_remote_config_instance.configSettings.isDeveloperModeEnabled ? "1" : "0";
  default:
    LogError("Remote Config: GetConfigSetting called with unknown setting: %d", setting);
    return std::string();
  }
}

void SetConfigSetting(ConfigSetting setting, const char *value) {
  switch (setting) {
  case kConfigSettingDeveloperMode:
    g_remote_config_instance.configSettings =
        [[FIRRemoteConfigSettings alloc] initWithDeveloperModeEnabled:@(value).boolValue];
    break;
  default:
    LogError("Remote Config: SetConfigSetting called with unknown setting: %d", setting);
    break;
  }
}

// Shared helper function for retrieving the FIRRemoteConfigValue.
static FIRRemoteConfigValue *GetValue(const char *key, const char *config_namespace,
                                      ValueInfo *info) {
  FIRRemoteConfigValue *value;
  if (config_namespace) {
    value = [g_remote_config_instance configValueForKey:@(key) namespace:@(config_namespace)];
  } else {
    value = [g_remote_config_instance configValueForKey:@(key)];
  }
  if (info) {
    int source_index = static_cast<int>(value.source);
    if (source_index >= 0 && source_index < sizeof(kFirebaseRemoteConfigSourceToValueSourceMap)) {
      info->source = kFirebaseRemoteConfigSourceToValueSourceMap[value.source];
      info->conversion_successful = true;
    } else {
      info->conversion_successful = false;
      LogWarning("Remote Config: Failed to find a valid source for the requested key %s", key);
    }
  }
  return value;
}

static void CheckBoolConversion(FIRRemoteConfigValue *value, ValueInfo *info) {
  if (info && info->conversion_successful) {
    NSError *error = nullptr;
    NSString *pattern = value.boolValue ? true_pattern : false_pattern;
    NSRegularExpression *regex =
        [NSRegularExpression regularExpressionWithPattern:pattern
                                                  options:NSRegularExpressionCaseInsensitive
                                                    error:&error];
    int matches = [regex numberOfMatchesInString:value.stringValue
                                         options:0
                                           range:NSMakeRange(0, [value.stringValue length])];
    info->conversion_successful = (matches == 1);
  }
}

bool GetBoolean(const char *key) { return GetBoolean(key, nullptr, nullptr); }
bool GetBoolean(const char *key, const char *config_namespace) {
  return GetBoolean(key, config_namespace, nullptr);
}
bool GetBoolean(const char *key, ValueInfo *info) { return GetBoolean(key, nullptr, info); }
bool GetBoolean(const char *key, const char *config_namespace, ValueInfo *info) {
  FIREBASE_ASSERT_RETURN(false, internal::IsInitialized());
  FIRRemoteConfigValue *value = GetValue(key, config_namespace, info);
  CheckBoolConversion(value, info);
  return static_cast<bool>(value.boolValue);
}

static void CheckLongConversion(FIRRemoteConfigValue *value, ValueInfo *info) {
  if (info && info->conversion_successful) {
    NSError *error = nullptr;
    NSRegularExpression *regex =
        [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+$"
                                                  options:NSRegularExpressionCaseInsensitive
                                                    error:&error];
    int matches = [regex numberOfMatchesInString:value.stringValue
                                         options:0
                                           range:NSMakeRange(0, [value.stringValue length])];
    info->conversion_successful = (matches == 1);
  }
}

int64_t GetLong(const char *key) { return GetLong(key, nullptr, nullptr); }
int64_t GetLong(const char *key, const char *config_namespace) {
  return GetLong(key, config_namespace, nullptr);
}
int64_t GetLong(const char *key, ValueInfo *info) { return GetLong(key, nullptr, info); }
int64_t GetLong(const char *key, const char *config_namespace, ValueInfo *info) {
  FIREBASE_ASSERT_RETURN(0, internal::IsInitialized());
  FIRRemoteConfigValue *value = GetValue(key, config_namespace, info);
  CheckLongConversion(value, info);
  return value.numberValue.longLongValue;
}

static void CheckDoubleConversion(FIRRemoteConfigValue *value, ValueInfo *info) {
  if (info && info->conversion_successful) {
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    [formatter setNumberStyle:NSNumberFormatterDecimalStyle];
    NSNumber *number = [formatter numberFromString:value.stringValue];
    if (!number) {
      info->conversion_successful = false;
    }
  }
}

double GetDouble(const char *key) { return GetDouble(key, nullptr, nullptr); }
double GetDouble(const char *key, const char *config_namespace) {
  return GetDouble(key, config_namespace, nullptr);
}
double GetDouble(const char *key, ValueInfo *info) { return GetDouble(key, nullptr, info); }
double GetDouble(const char *key, const char *config_namespace, ValueInfo *info) {
  FIREBASE_ASSERT_RETURN(0.0, internal::IsInitialized());
  FIRRemoteConfigValue *value = GetValue(key, config_namespace, info);
  CheckDoubleConversion(value, info);
  return value.numberValue.doubleValue;
}

std::string GetString(const char *key) { return GetString(key, nullptr, nullptr); }
std::string GetString(const char *key, const char *config_namespace) {
  return GetString(key, config_namespace, nullptr);
}
std::string GetString(const char *key, ValueInfo *info) { return GetString(key, nullptr, info); }
std::string GetString(const char *key, const char *config_namespace, ValueInfo *info) {
  FIREBASE_ASSERT_RETURN(std::string(), internal::IsInitialized());
  return util::NSStringToString(GetValue(key, config_namespace, info).stringValue);
}

std::vector<unsigned char> ConvertData(FIRRemoteConfigValue *value) {
  NSData *data = value.dataValue;
  int size = [data length] / sizeof(unsigned char);
  const unsigned char *bytes = static_cast<const unsigned char *>([data bytes]);
  return std::vector<unsigned char>(bytes, bytes + size);
}

std::vector<unsigned char> GetData(const char *key) { return GetData(key, nullptr, nullptr); }

std::vector<unsigned char> GetData(const char *key, const char *config_namespace) {
  return GetData(key, config_namespace, nullptr);
}

std::vector<unsigned char> GetData(const char *key, ValueInfo *info) {
  return GetData(key, nullptr, info);
}

std::vector<unsigned char> GetData(const char *key, const char *config_namespace, ValueInfo *info) {
  FIREBASE_ASSERT_RETURN(std::vector<unsigned char>(), internal::IsInitialized());
  return ConvertData(GetValue(key, config_namespace, info));
}

std::vector<std::string> GetKeysByPrefix(const char *prefix) {
  return GetKeysByPrefix(prefix, nullptr);
}

std::vector<std::string> GetKeysByPrefix(const char *prefix, const char *config_namespace) {
  FIREBASE_ASSERT_RETURN(std::vector<std::string>(), internal::IsInitialized());
  std::vector<std::string> keys;
  std::set<std::string> key_set;
  NSSet<NSString *> *ios_keys;
  NSString *prefix_string = prefix ? @(prefix) : nil;
  if (config_namespace) {
    ios_keys =
        [g_remote_config_instance keysWithPrefix:prefix_string namespace:@(config_namespace)];
  } else {
    ios_keys = [g_remote_config_instance keysWithPrefix:prefix_string];
  }
  for (NSString *key in ios_keys) {
    keys.push_back(key.UTF8String);
    key_set.insert(key.UTF8String);
  }

  // Add any extra keys that were previously included in defaults but not returned by
  // keysWithPrefix.
  const char* config_namespace_key = config_namespace ? config_namespace : kRootNamespace;
  std::vector<std::string> &vect =
      (*g_default_keys)[config_namespace_key];
  size_t prefix_length = prefix ? strlen(prefix) : 0;
  for (auto i = vect.begin(); i != vect.end(); ++i) {
    if (key_set.find(*i) != key_set.end()) {
      // Already in the list of keys, no need to add it.
      continue;
    }
    // If the prefix matches (or we have no prefix to compare), add it to the
    // defaults list.
    if (prefix_length == 0 || strncmp(prefix, i->c_str(), prefix_length) == 0) {
      keys.push_back(*i);
      key_set.insert(*i);  // In case the defaults vector has duplicate keys.
    }
  }

  return keys;
}

std::vector<std::string> GetKeys() { return GetKeysByPrefix(nullptr, nullptr); }

std::vector<std::string> GetKeys(const char *config_namespace) {
  return GetKeysByPrefix(nullptr, config_namespace);
}

Future<void> Fetch() { return Fetch(kDefaultCacheExpiration); }

Future<void> Fetch(uint64_t cache_expiration_in_seconds) {
  FIREBASE_ASSERT_RETURN(FetchLastResult(), internal::IsInitialized());
  ReferenceCountedFutureImpl *api = FutureData::Get()->api();
  const FutureHandle handle = api->Alloc<void>(kRemoteConfigFnFetch);

  FIRRemoteConfigFetchCompletion completion = ^(FIRRemoteConfigFetchStatus status, NSError *error) {
    if (error) {
      LogError("Remote Config: Fetch encountered an error: %s",
               util::NSStringToString(error.localizedDescription).c_str());
      if (error.userInfo) {
        g_throttled_end_time =
            ((NSNumber *)error.userInfo[FIRRemoteConfigThrottledEndTimeInSecondsKey]);
      }
      // If we got an error code back, return that, with the associated string.
      api->Complete(handle, kFetchFutureStatusFailure,
                    util::NSStringToString(error.localizedDescription).c_str());
    } else if (status != FIRRemoteConfigFetchStatusSuccess) {
          api->Complete(handle, kFetchFutureStatusFailure,
                        "Fetch encountered an error.");
    } else {
      // Everything worked!
      api->Complete(handle, kFetchFutureStatusSuccess, nullptr);
    }
  };
  [g_remote_config_instance fetchWithExpirationDuration:cache_expiration_in_seconds
                                      completionHandler:completion];

  return static_cast<const Future<void> &>(api->LastResult(kRemoteConfigFnFetch));
}

Future<void> FetchLastResult() {
  FIREBASE_ASSERT_RETURN(Future<void>(), internal::IsInitialized());
  ReferenceCountedFutureImpl *api = FutureData::Get()->api();
  return static_cast<const Future<void> &>(api->LastResult(kRemoteConfigFnFetch));
}

bool ActivateFetched() {
  FIREBASE_ASSERT_RETURN(false, internal::IsInitialized());
  return static_cast<bool>([g_remote_config_instance activateFetched]);
}

const ConfigInfo &GetInfo() {
  static const uint64_t kMillisecondsPerSecond = 1000;
  static ConfigInfo kConfigInfo;
  FIREBASE_ASSERT_RETURN(kConfigInfo, internal::IsInitialized());
  kConfigInfo.fetch_time =
      round(g_remote_config_instance.lastFetchTime.timeIntervalSince1970 * kMillisecondsPerSecond);
  kConfigInfo.throttled_end_time = g_throttled_end_time.longLongValue * kMillisecondsPerSecond;
  switch (g_remote_config_instance.lastFetchStatus) {
  case FIRRemoteConfigFetchStatusNoFetchYet:
    kConfigInfo.last_fetch_status = kLastFetchStatusPending;
    kConfigInfo.last_fetch_failure_reason = kFetchFailureReasonInvalid;
    break;
  case FIRRemoteConfigFetchStatusSuccess:
    kConfigInfo.last_fetch_status = kLastFetchStatusSuccess;
    kConfigInfo.last_fetch_failure_reason = kFetchFailureReasonInvalid;
    break;
  case FIRRemoteConfigFetchStatusFailure:
    kConfigInfo.last_fetch_status = kLastFetchStatusFailure;
    kConfigInfo.last_fetch_failure_reason = kFetchFailureReasonError;
    break;
  case FIRRemoteConfigFetchStatusThrottled:
    kConfigInfo.last_fetch_status = kLastFetchStatusFailure;
    kConfigInfo.last_fetch_failure_reason = kFetchFailureReasonThrottled;
    break;
  default:
    LogError("Remote Config: Received unknown last fetch status: %d",
             g_remote_config_instance.lastFetchStatus);
    kConfigInfo.last_fetch_status = kLastFetchStatusFailure;
    kConfigInfo.last_fetch_failure_reason = kFetchFailureReasonError;
    break;
  }
  return kConfigInfo;
}

}  // namespace remote_config
}  // namespace firebase
