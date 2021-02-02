//
//  UnityAdsPlugin.mm
//  UnityAds Plugin
//
//  Copyright (c) 2016 Corona Labs Inc. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "CoronaRuntime.h"
#import "CoronaAssert.h"
#import "CoronaEvent.h"
#import "CoronaLua.h"
#import "CoronaLuaIOS.h"
#import "CoronaLibrary.h"

#import "UnityAdsPlugin.h"
#import <UnityAds/UnityAds.h>
#import <AppTrackingTransparency/AppTrackingTransparency.h>

// some macros to make life easier, and code more readable
#define UTF8StringWithFormat(format, ...) [[NSString stringWithFormat:format, ##__VA_ARGS__] UTF8String]
#define UTF8IsEqual(utf8str1, utf8str2) (strcmp(utf8str1, utf8str2) == 0)
#define MsgFormat(format, ...) [NSString stringWithFormat:format, ##__VA_ARGS__]

// ----------------------------------------------------------------------------
// Plugin Constants
// ----------------------------------------------------------------------------

#define PLUGIN_NAME        "plugin.unityads"
#define PLUGIN_VERSION     "1.0.9"
#define PLUGIN_SDK_VERSION [UnityAds getVersion]

static const char EVENT_NAME[]    = "adsRequest";
static const char PROVIDER_NAME[] = "unityads";

// ad types
static const char TYPE_UNITYAD[] = "unityAd";

// event phases
static NSString * const PHASE_INIT      = @"init";
static NSString * const PHASE_LOADED    = @"loaded";
static NSString * const PHASE_FAILED    = @"failed";
static NSString * const PHASE_SKIPPED   = @"skipped";
static NSString * const PHASE_COMPLETED = @"completed";
static NSString * const PHASE_DISPLAYED = @"displayed";
static NSString * const PHASE_PLACEMENT_STATUS = @"placementStatus";

// missing Corona event keys
static NSString * const CORONA_EVENT_DATA_KEY = @"data";

// data keys
static NSString * const DATA_PLACEMENT_ID_KEY = @"placementId";
static NSString * const DATA_STATUS_CODE_KEY  = @"statusCode";
static NSString * const DATA_STATUS_INFO_KEY  = @"statusInfo";
static NSString * const DATA_ERROR_CODE_KEY   = @"errorCode";
static NSString * const DATA_ERROR_MSG_KEY    = @"errorMsg";

// response codes
static NSString * const RESPONSE_SHOW_FAILED  = @"showFailed";

// message constants
static NSString * const ERROR_MSG   = @"ERROR: ";
static NSString * const WARNING_MSG = @"WARNING: ";

// ----------------------------------------------------------------------------
// plugin class and delegate definitions
// ----------------------------------------------------------------------------

// INT_MAX used to define no data for delegate function params
#define NO_DATA ((UnityAdsError)-1)

// UnityAds delegate
@interface CoronaUnityAdsDelegate: NSObject <UnityAdsDelegate>

@property (nonatomic, assign) CoronaLuaRef coronaListener;             // Reference to the Lua listener
@property (nonatomic, assign) id<CoronaRuntime> coronaRuntime;           // Pointer to the Corona runtime

- (void)dispatchLuaEvent:(NSDictionary *)dict;
- (NSString *)getJSONStringForPlacement:(NSString *)placementId error:(UnityAdsError)error;
- (NSString *)getPlacementErrorInfo:(UnityAdsError)error;

@end

// ----------------------------------------------------------------------------

class UnityAdsPlugin
{
  public:
    typedef UnityAdsPlugin Self;
    
  public:
    static const char kName[];
    
  public:
    static int Open( lua_State *L );
    static int Finalizer( lua_State *L );
    static Self *ToLibrary( lua_State *L );
    
  protected:
    UnityAdsPlugin();
    bool Initialize( void *platformContext );
    
  public:
    static int init( lua_State *L );
    static int isLoaded( lua_State *L );
    static int show( lua_State *L );
    static int setHasUserConsent(lua_State *L);
    
  private: // internal helper functions
    static void logMsg(lua_State *L, NSString *msgType,  NSString *errorMsg);
    static bool isSDKInitialized(lua_State *L);
    
  private:
    NSString *functionSignature;                                  // used in logMsg to identify function
    UIViewController *coronaViewController;                       // application's view controller
};

const char UnityAdsPlugin::kName[] = PLUGIN_NAME;
CoronaUnityAdsDelegate *unityadsDelegate;                         // UnityAds delegate

// ----------------------------------------------------------------------------
// helper functions
// ----------------------------------------------------------------------------

// log message to console
void
UnityAdsPlugin::logMsg(lua_State *L, NSString* msgType, NSString* errorMsg)
{
  Self *context = ToLibrary(L);
  
  if (context) {
    Self& library = *context;
    
    NSString *functionID = [library.functionSignature copy];
    if (functionID.length > 0) {
      functionID = [functionID stringByAppendingString:@", "];
    }
    
    CoronaLuaLogPrefix(L, [msgType UTF8String], UTF8StringWithFormat(@"%@%@", functionID, errorMsg));
  }
}

// check if SDK calls can be made
bool
UnityAdsPlugin::isSDKInitialized(lua_State *L)
{
  // has init() been called?
  if (unityadsDelegate.coronaListener == NULL) {
    logMsg(L, ERROR_MSG, @"unityads.init() must be called before calling other API methods");
    return false;
  }
  
  return true;
}

// ----------------------------------------------------------------------------
// plugin implementation
// ----------------------------------------------------------------------------

int
UnityAdsPlugin::Open( lua_State *L )
{
  // Register __gc callback
  const char kMetatableName[] = __FILE__; // Globally unique string to prevent collision
  CoronaLuaInitializeGCMetatable( L, kMetatableName, Finalizer );
  
  //CoronaLuaInitializeGCMetatable( L, kMetatableName, Finalizer );
  void *platformContext = CoronaLuaGetContext( L );
  
  // Set library as upvalue for each library function
  Self *library = new Self;
  
  if ( library->Initialize( platformContext ) ) {
    // Functions in library
    static const luaL_Reg kFunctions[] = {
      {"init", init},
      {"isLoaded", isLoaded},
      {"show", show},
      {"setHasUserConsent", setHasUserConsent},
      {NULL, NULL}
    };
    
    // Register functions as closures, giving each access to the
    // 'library' instance via ToLibrary()
    {
      CoronaLuaPushUserdata( L, library, kMetatableName );
      luaL_openlib( L, kName, kFunctions, 1 ); // leave "library" on top of stack
    }
  }
  
  return 1;
}

int
UnityAdsPlugin::Finalizer( lua_State *L )
{
  Self *library = (Self *)CoronaLuaToUserdata(L, 1);
  
  // Free the Lua listener
  CoronaLuaDeleteRef(L, unityadsDelegate.coronaListener);
  unityadsDelegate = nil;
  
  delete library;
  
  return 0;
}

UnityAdsPlugin*
UnityAdsPlugin::ToLibrary( lua_State *L )
{
  // library is pushed as part of the closure
  Self *library = (Self *)CoronaLuaToUserdata( L, lua_upvalueindex( 1 ) );
  return library;
}

UnityAdsPlugin::UnityAdsPlugin()
: coronaViewController( nil )
{
}

bool
UnityAdsPlugin::Initialize( void *platformContext )
{
  bool shouldInit = (! coronaViewController);
  
  if ( shouldInit ) {
    id<CoronaRuntime> runtime = (__bridge id<CoronaRuntime>)platformContext;
    coronaViewController = runtime.appViewController;
    
    functionSignature = @"";
    
    // initialize the delegate
    unityadsDelegate = [CoronaUnityAdsDelegate new];
    unityadsDelegate.coronaRuntime = runtime;
  }
  
  return shouldInit;
}

// [Lua] unityAds.init(listener, options)
int
UnityAdsPlugin::init( lua_State *L )
{
  Self *context = ToLibrary(L);
  
  if (! context) { // abort if no valid context
    return 0;
  }
  
  Self& library = *context;
  
  library.functionSignature = @"unityAds.init(listener, options)";
  
  // prevent init from being called twice
  if (unityadsDelegate.coronaListener != NULL) {
    logMsg(L, WARNING_MSG, @"init() should only be called once");
    return 0;
  }
  
  // get number of arguments
  int nargs = lua_gettop(L);
  if (nargs != 2) {
    logMsg(L, ERROR_MSG, MsgFormat(@"Expected 2 arguments, got %d", nargs));
    return 0;
  }
  
  const char *gameId = NULL;
  bool testMode = false;
  
  // Get listener key (required)
  if (CoronaLuaIsListener(L, 1, PROVIDER_NAME)) {
    unityadsDelegate.coronaListener = CoronaLuaNewRef(L, 1);
  }
  else {
    logMsg(L, ERROR_MSG, MsgFormat(@"listener expected, got: %s", luaL_typename(L, 1)));
    return 0;
  }
  
  // check for options table (required)
  if (lua_type(L, 2) == LUA_TTABLE) {
    // traverse and verify all options
    for (lua_pushnil(L); lua_next(L, 2) != 0; lua_pop(L, 1)) {
      const char *key = lua_tostring(L, -2);
      
      if (UTF8IsEqual(key, "gameId")) {
        if (lua_type(L, -1) == LUA_TSTRING) {
          gameId = lua_tostring(L, -1);
        }
        else {
          logMsg(L, ERROR_MSG, MsgFormat(@"options.gameId (string) expected, got: %s", luaL_typename(L, -1)));
          return 0;
        }
      }
      else if (UTF8IsEqual(key, "testMode")) {
        if (lua_type(L, -1) == LUA_TBOOLEAN) {
          testMode = lua_toboolean(L, -1);
        }
        else {
          logMsg(L, ERROR_MSG, MsgFormat(@"options.testMode (boolean) expected, got: %s", luaL_typename(L, -1)));
          return 0;
        }
      }
      else {
        logMsg(L, ERROR_MSG, MsgFormat(@"Invalid option '%s'", key));
        return 0;
      }
    }
  }
  // no options table
  else {
    logMsg(L, ERROR_MSG, MsgFormat(@"options table expected, got %s", luaL_typename(L, 2)));
    return 0;
  }
  
  // validate gameId
  if (gameId == NULL) {
    logMsg(L, ERROR_MSG, @"options.gameId required");
    return 0;
  }
  
  // log plugin version to the console
  NSLog(@"%s: %s (SDK: %@)", PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_SDK_VERSION);
  
  // initialize the SDK
  	bool noAtt = true;
	if (@available(iOS 14, tvOS 14, *)) {
		if([[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSUserTrackingUsageDescription"]) {
			noAtt = false;
			[ATTrackingManager requestTrackingAuthorizationWithCompletionHandler:^(ATTrackingManagerAuthorizationStatus status) {
				[[NSOperationQueue mainQueue] addOperationWithBlock:^{
					[UnityAds initialize:@(gameId) delegate:unityadsDelegate testMode:testMode];
				}];
			}];
		}
	}
	if(noAtt) {
		[UnityAds initialize:@(gameId) delegate:unityadsDelegate testMode:testMode];
	}

  
  
  
  // send Lua event
  NSDictionary *coronaEvent = @{
    @(CoronaEventPhaseKey()) : PHASE_INIT
  };
  [unityadsDelegate dispatchLuaEvent:coronaEvent];
  
  return 0;
}

// [Lua] unityads.isLoaded(placementId) -> boolean
int
UnityAdsPlugin::isLoaded( lua_State *L )
{
  Self *context = ToLibrary(L);
  
  if (! context) { // abort if no valid context
    return 0;
  }
  
  Self& library = *context;
  
  library.functionSignature = @"unityads.isLoaded(placementId)";
  
  if (! isSDKInitialized(L)) {
    return 0;
  }
  
  // get number of arguments
  int nargs = lua_gettop(L);
  if (nargs != 1) {
    logMsg(L, ERROR_MSG, MsgFormat(@"Expected 1 argument, got %d", nargs));
    return 0;
  }
  
  const char *placementId = NULL;
  
  if (lua_type(L, 1) == LUA_TSTRING) {
    placementId = lua_tostring(L, 1);
  }
  else {
    logMsg(L, ERROR_MSG, MsgFormat(@"placementId expected (string), got %s", luaL_typename(L, 1)));
    return 0;
  }
  
  // get the placement status
  UnityAdsPlacementState placementState = [UnityAds getPlacementState:@(placementId)];
  NSString *statusInfo;
  
  if (placementState == kUnityAdsPlacementStateReady) {
    statusInfo = @"Ready";
  }
  else if (placementState == kUnityAdsPlacementStateWaiting) {
    statusInfo = @"Loading";
  }
  else if (placementState == kUnityAdsPlacementStateDisabled) {
    statusInfo = @"Disabled in dashboard";
  }
  else if (placementState == kUnityAdsPlacementStateNotAvailable) {
    statusInfo = @"Configuration error";
  }
  else if (placementState == kUnityAdsPlacementStateNoFill) {
    statusInfo = @"No fill";
  }
  else {
	statusInfo = @"Unknown";
  }
  
  // create the JSON response
  NSMutableDictionary *dataDictionary = [NSMutableDictionary new];
  dataDictionary[DATA_PLACEMENT_ID_KEY] = @(placementId);
  dataDictionary[DATA_STATUS_CODE_KEY] = @(placementState);
  dataDictionary[DATA_STATUS_INFO_KEY] = statusInfo;
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dataDictionary options:0 error:nil];
  NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
  
  // send Corona Lua event
  NSDictionary *coronaEvent = @{
    @(CoronaEventPhaseKey()) : PHASE_PLACEMENT_STATUS,
    @(CoronaEventTypeKey()) : @(TYPE_UNITYAD),
    CORONA_EVENT_DATA_KEY : jsonString
  };
  [unityadsDelegate dispatchLuaEvent:coronaEvent];
  
  bool isLoaded = [UnityAds isReady:@(placementId)];
  lua_pushboolean(L, isLoaded);
  
  return 1;
}

//  [Lua] unityads.show(placementId)
int
UnityAdsPlugin::show( lua_State *L )
{
  Self *context = ToLibrary(L);
  
  if (! context) { // abort if no valid context
    return 0;
  }
  
  Self& library = *context;
  
  library.functionSignature = @"unityads.show(placementId)";
  
  if ( ! isSDKInitialized(L) ) {
    return 0;
  }
  
  // get number of arguments
  int nargs = lua_gettop(L);
  if (nargs != 1) {
    logMsg(L, ERROR_MSG, MsgFormat(@"Expected 1 argument, got %d", nargs));
    return 0;
  }
  
  const char *placementId = NULL;
  
  if (lua_type(L, 1) == LUA_TSTRING) {
    placementId = lua_tostring(L, 1);
  }
  else {
    logMsg(L, ERROR_MSG, MsgFormat(@"placementId expected (string), got %s", luaL_typename(L, 1)));
    return 0;
  }
  
  bool isLoaded = [UnityAds isReady:@(placementId)];
  if (! isLoaded) {
    logMsg(L, WARNING_MSG, MsgFormat(@"placementId '%s' not loaded", placementId));
    return 0;
  }
  
  // show an ad
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    [UnityAds show:library.coronaViewController placementId:@(placementId)];
  }];
  
  return 0;
}

// [Lua] unityads.setHasUserConsent( bool )
int
UnityAdsPlugin::setHasUserConsent(lua_State *L)
{
    Self *context = ToLibrary(L);

    if (! context) { // abort if no valid context
        return 0;
    }

    Self& library = *context;

    library.functionSignature = @"unityads.setHasUserConsent( bool )";

    if (! isSDKInitialized(L)) {
        return 0;
    }

    // check number of arguments
    int nargs = lua_gettop(L);
    if (nargs != 1) {
        logMsg(L, ERROR_MSG, MsgFormat(@"Expected 1 argument, got %d", nargs));
        return 0;
    }

    int hasUserConsent = NULL;

    // check options
    if (lua_type(L, 1) == LUA_TBOOLEAN) {
        hasUserConsent = lua_toboolean(L, -1);
    }
    else {
        logMsg(L, ERROR_MSG, MsgFormat(@"hasUserConsent (bool) expected, got %s", luaL_typename(L, 1)));
        return 0;
    }

    UADSMetaData *gdprConsentMetaData = [[UADSMetaData alloc] init];
    [gdprConsentMetaData set:@"gdpr.consent" value:@(hasUserConsent!=0)];
    [gdprConsentMetaData commit];

    return 0;
}

// ============================================================================
// delegate implementation
// ============================================================================

@implementation CoronaUnityAdsDelegate

- (instancetype)init {
  if (self = [super init]) {
    self.coronaListener = NULL;
    self.coronaRuntime = NULL;
  }
  
  return self;
}

// dispatch a new Lua event
- (void)dispatchLuaEvent:(NSDictionary *)dict
{
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    lua_State *L = self.coronaRuntime.L;
    CoronaLuaRef coronaListener = self.coronaListener;
    bool hasErrorKey = false;
    
    // create new event
    CoronaLuaNewEvent(L, EVENT_NAME);
    
    for (NSString *key in dict) {
      CoronaLuaPushValue(L, [dict valueForKey:key]);
      lua_setfield(L, -2, key.UTF8String);
      
      if (! hasErrorKey) {
        hasErrorKey = [key isEqualToString:@(CoronaEventIsErrorKey())];
      }
    }
    
    // add error key if not in dict
    if (! hasErrorKey) {
      lua_pushboolean(L, false);
      lua_setfield(L, -2, CoronaEventIsErrorKey());
    }
    
    // add provider
    lua_pushstring(L, PROVIDER_NAME );
    lua_setfield(L, -2, CoronaEventProviderKey());
    
    CoronaLuaDispatchEvent(L, coronaListener, 0);
  }];
}

// get human readable error info
- (NSString *)getPlacementErrorInfo:(UnityAdsError)error
{
  NSString *errorStr;
  
  switch (error) {
    case kUnityAdsErrorNotInitialized:
      errorStr = @"UnityAds not initialized";
      break;
    case kUnityAdsErrorInitializedFailed:
      errorStr = @"Initialization failed";
      break;
    case kUnityAdsErrorInvalidArgument:
      errorStr = @"Invalid parameters during initialization";
      break;
    case kUnityAdsErrorVideoPlayerError:
      errorStr = @"Video Player failure";
      break;
    case kUnityAdsErrorInitSanityCheckFail:
      errorStr = @"UnityAds initialization sanity check error";
      break;
    case kUnityAdsErrorAdBlockerDetected:
      errorStr = @"Ad blocker detected";
      break;
    case kUnityAdsErrorFileIoError:
      errorStr = @"File I/O error";
      break;
    case kUnityAdsErrorDeviceIdError:
      errorStr = @"Bad device identifier";
      break;
    case kUnityAdsErrorShowError:
      errorStr = @"Failed to show ad";
      break;
    case kUnityAdsErrorInternalError:
      errorStr = @"Internal error";
      break;
    default:
      errorStr = [NSString stringWithFormat:@"Unknown error %lu", (unsigned long)error];
  }
  
  return errorStr;
}

// create JSON string from placement, reward and error
- (NSString *)getJSONStringForPlacement:(NSString *)placementId error:(UnityAdsError)error;
{
  NSMutableDictionary *dataDictionary = [NSMutableDictionary new];
  
  if (placementId != nil) {
    dataDictionary[DATA_PLACEMENT_ID_KEY] = placementId;
  }
  
  if (error != NO_DATA) {
    dataDictionary[DATA_ERROR_MSG_KEY] = [self getPlacementErrorInfo:error];
    dataDictionary[DATA_ERROR_CODE_KEY] = @(error);
  }
  
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dataDictionary options:0 error:nil];
  
  return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

- (void)unityAdsReady:(NSString *)placementId
{
  // send Corona Lua event
  NSDictionary *coronaEvent = @{
    @(CoronaEventPhaseKey()) : PHASE_LOADED,
    @(CoronaEventTypeKey()) : @(TYPE_UNITYAD),
    CORONA_EVENT_DATA_KEY : [self getJSONStringForPlacement:placementId error:NO_DATA]
  };
  [self dispatchLuaEvent:coronaEvent];
  
}

- (void)unityAdsDidStart:(NSString *)placementId
{
  // send Corona Lua event
  NSDictionary *coronaEvent = @{
    @(CoronaEventPhaseKey()) : PHASE_DISPLAYED,
    @(CoronaEventTypeKey()) : @(TYPE_UNITYAD),
    CORONA_EVENT_DATA_KEY : [self getJSONStringForPlacement:placementId error:NO_DATA]
  };
  [self dispatchLuaEvent:coronaEvent];
  
}

-(void)unityAdsDidError:(UnityAdsError)error withMessage:(NSString *)message
{
  // send Corona Lua event
  NSDictionary *coronaEvent = @{
    @(CoronaEventPhaseKey()) : PHASE_FAILED,
    @(CoronaEventIsErrorKey()) : @(true),
    @(CoronaEventTypeKey()) : @(TYPE_UNITYAD),
    @(CoronaEventResponseKey()) : message,
    CORONA_EVENT_DATA_KEY : [self getJSONStringForPlacement:nil error:error]
  };
  [self dispatchLuaEvent:coronaEvent];
}

-(void)unityAdsDidFinish:(NSString *)placementId withFinishState:(UnityAdsFinishState)state
{
  NSString *phase = @"unknown";
  
  // prepare Corona Lua event
  NSMutableDictionary *coronaEvent = [@{
    @(CoronaEventTypeKey()) : @(TYPE_UNITYAD),
    CORONA_EVENT_DATA_KEY : [self getJSONStringForPlacement:placementId error:NO_DATA]
  } mutableCopy];
  
  if (state == kUnityAdsFinishStateError) {
    phase = PHASE_FAILED;
    coronaEvent[@(CoronaEventIsErrorKey())] = @(true);
    coronaEvent[@(CoronaEventResponseKey())] = RESPONSE_SHOW_FAILED;
  }
  else if (state == kUnityAdsFinishStateSkipped) {
    phase = PHASE_SKIPPED;
  }
  else if (state == kUnityAdsFinishStateCompleted) {
    phase = PHASE_COMPLETED;
  }
  
  coronaEvent[@(CoronaEventPhaseKey())] = phase;
  
  // send Corona Lua event
  [self dispatchLuaEvent:coronaEvent];
}

@end

// ----------------------------------------------------------------------------

CORONA_EXPORT int
luaopen_plugin_unityads( lua_State *L )
{
  return UnityAdsPlugin::Open( L );
}
