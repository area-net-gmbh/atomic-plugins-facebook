#import "LDFacebookService.h"
#import <FBSDKCoreKit/FBSDKCoreKit.h>
#import <FBSDKCoreKit/FBSDKWebDialog.h>
#import <FBSDKLoginKit/FBSDKLoginKit.h>
#import <FBSDKShareKit/FBSDKShareKit.h>

static LDFacebookSession * fromToken(FBSDKAccessToken * token) {
    LDFacebookSession * result = [[LDFacebookSession alloc] init];
    if (token) {
        result.state = LDFacebookSessionStateOpen;
        result.permissions = [token.permissions allObjects];
        result.accessToken = token.tokenString;
        result.expirationDate = result.expirationDate;
    }
    else {
        result.state = LDFacebookSessionStateNotAuthorized;
    }
    
    FBSDKProfile * profile = [FBSDKProfile currentProfile];
    if (profile) {
        result.user = @{
                        @"id": profile.userID ?: @"",
                        @"first_name": profile.firstName ?: @"",
                        @"last_name": profile.lastName ?: @"",
                        @"name": profile.name ?: @"",
                        @"link": profile.linkURL ? profile.linkURL.absoluteString : @"",
                        };
    }
    else {
        result.user = nil;
    }
    
    return result;
}

NSDictionary * fbError(NSError* error)
{
    if (error) {
        return @{ @"error": @{
                            @"code": [NSNumber numberWithInteger:error.code],
                            @"message": [error.userInfo objectForKey:FBSDKErrorDeveloperMessageKey] ?: @""
                          }
                };
    }
    return nil;
}


@implementation LDFacebookSession

@end

@interface LDFacebookService() <FBSDKWebDialogDelegate, FBSDKSharingDelegate, FBSDKGameRequestDialogDelegate>
@end


@implementation LDFacebookService
{
    NSDictionary * _cachedUser;
    void (^_profileNotificationTask)();
    LDFacebookCompletion _gameRequestDialogCompletion;
    LDFacebookCompletion _webDialogCompletion;
    LDFacebookCompletion _shareCompletion;
    
}

#pragma mark Initializers
+ (void)load
{
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didFinishLaunchingNotitification:) name:@"UIApplicationDidFinishLaunchingNotification" object:nil];
}

+ (void)didFinishLaunchingNotitification:(NSNotification *)notification
{
    [FBSDKProfile enableUpdatesOnAccessTokenChange:YES];
    [[FBSDKApplicationDelegate sharedInstance] application:[UIApplication sharedApplication] didFinishLaunchingWithOptions:notification.userInfo];
}

-(id) init {
    if (self = [super init]) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didChangeProfileNotification:) name:FBSDKProfileDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(openUrl:) name:@"CocoonHandleOpenURLNotification" object:nil];
    }
    return self;
}

-(void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark API

+(BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation
{
    return [[FBSDKApplicationDelegate sharedInstance] application:application
                                                          openURL:url
                                                sourceApplication:sourceApplication
                                                       annotation:annotation
            ];
}

-(void) initialize:(NSDictionary*) params
{
    self.params = params;
    FBSDKAccessToken * session = [FBSDKAccessToken currentAccessToken];
    [FBSDKAppEvents activateApp];
    if (session) {
        [self processSessionChange:session error:nil handler:nil];
    }
}

-(void) logEvent:(NSString*) name
{
    [FBSDKAppEvents logEvent:name];

}

-(BOOL) isLoggedIn
{
    FBSDKAccessToken * session = [FBSDKAccessToken currentAccessToken];
    return session && session.tokenString;
}

-(void) loginWithReadPermissions:(NSArray *) permissions fromViewController:(UIViewController*) vc completion:(LDFacebookSessionHandler) completion
{
    if ([self isLoggedIn]) {
        [self requestAdditionalPermissions:@"read" permissions:permissions fromViewController:vc completion:completion];
        return;
    }

    FBSDKLoginManager * manager = [[FBSDKLoginManager alloc] init];
    [manager setLoginBehavior:FBSDKLoginBehaviorNative];
    [manager logInWithReadPermissions:permissions fromViewController:vc handler:^(FBSDKLoginManagerLoginResult *result, NSError *error) {
        if (result.isCancelled) {
            [self processSessionChange:nil error:nil handler:completion];
        }
        else {
            [self processSessionChange:[FBSDKAccessToken currentAccessToken] error:error handler:completion];
        }
    }];
}

-(void) logout
{
    FBSDKLoginManager * manager = [[FBSDKLoginManager alloc] init];
    [manager logOut];
    [self processSessionChange:[FBSDKAccessToken currentAccessToken] error:nil handler:nil];
}

-(void) getLoginStatus:(BOOL) force completion:(LDFacebookSessionHandler) completion {
    FBSDKAccessToken * session = [FBSDKAccessToken currentAccessToken];
    if (completion) {
        completion(fromToken(session), nil);
    }
}

-(void) requestAdditionalPermissions:(NSString *) permissionType permissions:(NSArray *) permissions fromViewController:(UIViewController*) vc  completion:(LDFacebookSessionHandler) completion
{
    FBSDKAccessToken * session = [FBSDKAccessToken currentAccessToken];
    
    BOOL ready = session != NULL;
    if (session && permissions) {
        for (NSString * str in permissions) {
            if (![session hasGranted:str]) {
                ready = NO;
                break;
            }
        }
    }
    
    if (ready) {
        if (completion) {
            completion(fromToken(session), nil);
        }
    }
    else if ([[permissionType lowercaseString] isEqualToString:@"publish"]) {
        FBSDKLoginManager * manager = [[FBSDKLoginManager alloc] init];
        [manager setLoginBehavior:FBSDKLoginBehaviorSystemAccount];
        [manager logInWithPublishPermissions:permissions fromViewController:vc handler:^(FBSDKLoginManagerLoginResult *result, NSError *error) {
            if (result.isCancelled) {
                [self processSessionChange:nil error:nil handler:completion];
            }
            else {
                [self processSessionChange:[FBSDKAccessToken currentAccessToken] error:error handler:completion];
            }
        }];
    }
    else {
        FBSDKLoginManager * manager = [[FBSDKLoginManager alloc] init];
        [manager setLoginBehavior:FBSDKLoginBehaviorSystemAccount];
        [manager logInWithReadPermissions:permissions fromViewController:vc handler:^(FBSDKLoginManagerLoginResult *result, NSError *error) {
            if (result.isCancelled) {
                [self processSessionChange:nil error:nil handler:completion];
            }
            else {
                [self processSessionChange:[FBSDKAccessToken currentAccessToken] error:error handler:completion];
            }
        }];
        
    }
}

-(void) api:(NSString *) openGraph method:(NSString*) httpMethod params:(NSDictionary*) params completion:(LDFacebookCompletion) completion
{
    
    if (httpMethod.length == 0) {
        httpMethod = @"GET";
    }
    
    FBSDKGraphRequest * request = [[FBSDKGraphRequest alloc] initWithGraphPath:openGraph parameters:params HTTPMethod:[httpMethod uppercaseString]];
    [request startWithCompletionHandler:^(FBSDKGraphRequestConnection *connection, id result, NSError *error) {

        if (!completion) {
            return;
        }
        NSDictionary * response = nil;
        if (error) {
            response = fbError(error);
        }
        else if (result && [result isKindOfClass:[NSDictionary class]]) {
            response = result;
        }
        else if (result) {
            response = @{@"result":result};
        };
        completion(response, error);
    }];
    
}

-(void) ui:(NSString*) methodName params:(NSDictionary*) params fromViewController:(UIViewController*) vc completion:(LDFacebookCompletion) completion
{
    if ([methodName isEqualToString:@"apprequests"]) {
        _gameRequestDialogCompletion = completion;
        
        FBSDKGameRequestDialog *dialog = [[FBSDKGameRequestDialog alloc] init];
        [dialog setDelegate:self];
        if (![dialog canShow]) {
            NSError * error = [NSError errorWithDomain:@"Facebook" code:0 userInfo:@{FBSDKErrorDeveloperMessageKey:@"Can't show dialog"}];
            completion(fbError(error), error);
            return;
        }
        
        FBSDKGameRequestContent *content = [[FBSDKGameRequestContent alloc] init];
        NSString *actionType = params[@"action_type"];
        if (actionType) {
            if ([[actionType lowercaseString] isEqualToString:@"askfor"]) {
                content.actionType = FBSDKGameRequestActionTypeAskFor;
            } else if ([[actionType lowercaseString] isEqualToString:@"send"]) {
                content.actionType = FBSDKGameRequestActionTypeSend;
            } else if ([[actionType lowercaseString] isEqualToString:@"turn"]) {
                content.actionType = FBSDKGameRequestActionTypeTurn;
            }
        }
        
        if (params[@"filters"]) {
            if ([params[@"filters"] isKindOfClass:[NSArray class]]) {
                content.filters = FBSDKGameRequestFilterNone;
                
                NSArray* filters = params[@"filters"];
                if (filters.count > 0) {
                    if ([params[@"filters"][0] isEqualToString:@"app_users"]) {
                        content.filters = FBSDKGameRequestFilterAppUsers;
                    } else if ([params[@"filters"][0] isEqualToString:@"app_non_users"]) {
                        content.filters = FBSDKGameRequestFilterAppNonUsers;
                    }
                }
            }
        }
        
        if (params[@"data"]) {
            NSError *error;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:params[@"data"]
                                                               options:NSJSONWritingPrettyPrinted // Pass 0 if you don't care about the readability of the generated string
                                                                 error:&error];
            if (! jsonData) {
                completion(fbError(error), error);
                return;
            }
            content.data = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        }
        
        if (params[@"message"])
            content.message = params[@"message"];
        if (params[@"object_id"])
            content.objectID = params[@"object_id"];
        if ([params[@"to"] isKindOfClass:[NSArray class]])
            content.recipients = params[@"to"];
        else if ([params[@"to"] isKindOfClass:[NSString class]])
            content.recipients = @[ params[@"to"] ];
        if (params[@"title"])
            content.title = params[@"title"];
        
        dialog.content = content;
        if (self.params[@"frictionlessRequests"] != NULL)
            [dialog setFrictionlessRequestsEnabled:[self.params[@"frictionlessRequests"] boolValue]];
        [dialog show];
        return;
    
    } else {
        _webDialogCompletion = completion;
        [FBSDKWebDialog showWithName:methodName parameters:params delegate:self];
    }
}

-(void) showShareDialog:(NSDictionary*) params fromViewController:(UIViewController*) vc completion:(LDFacebookCompletion)completion
{
    _shareCompletion = completion;
    
    FBSDKShareLinkContent *content = [FBSDKShareLinkContent new];
    if ([params objectForKey:@"link"]) {
        content.contentURL = [NSURL URLWithString:[params objectForKey:@"link"]];
    }
    content.contentTitle = [params objectForKey:@"name"] ?: @"";
    content.contentDescription = [params objectForKey:@"description"] ?: @"";
    
    if ([params objectForKey:@"picture"]) {
        content.imageURL = [NSURL URLWithString:[params objectForKey:@"picture"]];
    }

    [FBSDKShareDialog showFromViewController:vc
                                 withContent:content
                                    delegate:self];
}

-(void) uploadPhoto:(NSString*) filePath completion:(LDFacebookCompletion) completion
{
    filePath = [filePath stringByReplacingOccurrencesOfString:@"file://" withString:@""];
    UIImage * image = [UIImage imageWithContentsOfFile:filePath];
    if (!image) {
        if (completion) {
            NSError * error = [NSError errorWithDomain:@"Facebook" code:0 userInfo:@{FBSDKErrorDeveloperMessageKey:@"Can't open image"}];
            completion(fbError(error), error);
        }
        return;
    }
    
    FBSDKGraphRequestConnection * connection = [FBSDKGraphRequestConnection new];
    // First request uploads the photo.
    [connection addRequest:[[FBSDKGraphRequest alloc] initWithGraphPath:@"me/photos" parameters:@{@"picture:":image} HTTPMethod:@"POST"] completionHandler:^(FBSDKGraphRequestConnection *connection, id result, NSError *error) {
        if (error && completion) {
            completion(fbError(error), error);
        }
        
    } batchEntryName:@"photopost"];
    [connection addRequest:[[FBSDKGraphRequest alloc] initWithGraphPath:@"{result=photopost:$.id}" parameters:nil] completionHandler:^(FBSDKGraphRequestConnection *connection, id result, NSError *error) {
        if (error && completion) {
            completion(fbError(error), nil);
        }
        else if (completion) {
            completion(result, nil);
        }
        
    }];
    [connection start];
}

#pragma mark Internal

- (void)openUrl:(NSNotification *)notification;
{
    [[FBSDKApplicationDelegate sharedInstance] application:[notification object][@"application"]
                                                   openURL:[notification object][@"url"]
                                         sourceApplication:[notification object][@"sourceApplication"]
                                                annotation:NULL
     ];
}

- (void)gameRequestDialog:(FBSDKGameRequestDialog *)gameRequestDialog didCompleteWithResults:(NSDictionary *)results
{
    if (_gameRequestDialogCompletion) {
        _gameRequestDialogCompletion(results, nil);
        _gameRequestDialogCompletion = nil;
    }
}

- (void)gameRequestDialog:(FBSDKGameRequestDialog *)gameRequestDialog didFailWithError:(NSError *)error
{
    if (_gameRequestDialogCompletion) {
        _gameRequestDialogCompletion(fbError(error), error);
        _gameRequestDialogCompletion = nil;
    }
}

- (void)gameRequestDialogDidCancel:(FBSDKGameRequestDialog *)gameRequestDialog
{
    if (_gameRequestDialogCompletion) {
        NSError * error = [NSError errorWithDomain:@"Facebook" code:0 userInfo:@{FBSDKErrorDeveloperMessageKey:@"Canceled by user"}];
        _gameRequestDialogCompletion(fbError(error), nil);
        _gameRequestDialogCompletion = nil;
    }
}

- (void)webDialog:(FBSDKWebDialog *)webDialog didCompleteWithResults:(NSDictionary *)results
{
    if (_webDialogCompletion) {
        _webDialogCompletion(results, nil);
        _webDialogCompletion = nil;
    }
}

- (void)webDialog:(FBSDKWebDialog *)webDialog didFailWithError:(NSError *)error
{
    if (_webDialogCompletion) {
        _webDialogCompletion(fbError(error), error);
        _webDialogCompletion = nil;
    }
}
- (void)webDialogDidCancel:(FBSDKWebDialog *)webDialog
{
    if (_webDialogCompletion) {
        _webDialogCompletion(nil, nil);
        _webDialogCompletion = nil;
    }
}


- (void)sharer:(id<FBSDKSharing>)sharer didCompleteWithResults:(NSDictionary *)results
{
    if (_shareCompletion) {
        _shareCompletion(results, nil);
        _shareCompletion = nil;
    }
}

- (void)sharer:(id<FBSDKSharing>)sharer didFailWithError:(NSError *)error
{
    if (_shareCompletion) {
        _shareCompletion(fbError(error), error);
        _shareCompletion = nil;
    }
}

- (void)sharerDidCancel:(id<FBSDKSharing>)sharer
{
    if (_shareCompletion) {
        _shareCompletion(nil, nil);
        _shareCompletion = nil;
    }
}


- (void)didChangeProfileNotification:(NSNotification *)notification
{
    if (_profileNotificationTask) {
        _profileNotificationTask();
        _profileNotificationTask = nil;
    }
}



-(void) notifyOnSessionChange:(LDFacebookSession*) session error:(NSError *) error handler:(LDFacebookSessionHandler) handler {
    if (_delegate && [_delegate respondsToSelector:@selector(facebookService:didChangeLoginStatus:error:)]) {
        [_delegate facebookService:self didChangeLoginStatus:session error:error];
    }
    if (handler) {
        handler(session, error);
    }
}

-(void) processSessionChange:(FBSDKAccessToken *) token error:(NSError *) error handler:(LDFacebookSessionHandler) handler
{
    if (error) {
        //error
        [self notifyOnSessionChange:fromToken(token) error:error handler:handler];
    }
    else if (token) {
        //logged in
        FBSDKProfile * profile = [FBSDKProfile currentProfile];
        if (profile) {
            [self notifyOnSessionChange:fromToken(token) error:nil handler:handler];
        }
        else {
            __weak LDFacebookService * weakSelf = self;
            _profileNotificationTask= ^() {
                if (weakSelf) {
                    LDFacebookSession * session = fromToken(token);
                    [weakSelf notifyOnSessionChange:session error:nil handler:handler];
                    if (handler) {
                        handler(session, error);
                    }
                }
            };
        }
        
    }
    else {
        //logged out or user cancelled login
        [self notifyOnSessionChange:fromToken(token) error:nil handler:handler];
        
    }
}

@end
