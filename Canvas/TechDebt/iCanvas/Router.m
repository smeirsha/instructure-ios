//
// Copyright (C) 2016-present Instructure, Inc.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3 of the License.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
    
    

#import <objc/runtime.h>

#import "Router.h"
#import "Router+Routes.h"
#import "CBIViewModel.h"
#import "CBISyllabusViewModel.h"
#import "UIViewController+Transitions.h"
#import <CanvasKit1/NSString+CKAdditions.h>
#import <CanvasKit1/CKCanvasAPI.h>
#import <CanvasKit1/CKContextInfo.h>
#import "CKCanvasAPI+CurrentAPI.h"


@interface UIViewController (Push)
@property (nonnull, readonly) UIViewController *currentLeaf;
@end

@implementation UIViewController (Push)
- (UIViewController *)currentLeaf {
    return self;
}
@end

@implementation UINavigationController (Push)
- (UIViewController *)currentLeaf {
    return self.topViewController.currentLeaf;
}
@end

@implementation UITabBarController (Push)
- (UIViewController *)currentLeaf {
    return self.selectedViewController.currentLeaf;
}
@end

@implementation UISplitViewController (Push)
- (UIViewController *)currentLeaf {
    return [self.viewControllers lastObject].currentLeaf;
}
@end

@import CanvasKit;
@import CanvasKeymaster;

@interface Router ()
@property NSMutableDictionary *routes;
@property NSNumberFormatter *numberFormatter;
@end

@implementation UIViewController (Routing)

- (void)applyRoutingParameters:(NSDictionary *)params {
    [params enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
        NSString *selectorString;
        
        objc_property_t prop = class_getProperty([self class], [key UTF8String]);
        char *setterName = property_copyAttributeValue(prop, "S");
        if (setterName) {
            selectorString = [NSString stringWithFormat:@"%s", setterName];
        }
        else {
            const char *selName = [key UTF8String];
            selectorString = [NSString stringWithFormat:@"set%c%s:", toupper(selName[0]), selName+1];
        }
        
        SEL selector = NSSelectorFromString(selectorString);
        if ([self respondsToSelector:selector]) {
            [self setValue:obj forKey:key];
        }
    }];
}

@end

@implementation Router

- (id)init {
    self = [super init];
    if (self) {
        _routes = [NSMutableDictionary new];
        _numberFormatter = [NSNumberFormatter new];
        [self configureInitialRoutes];
    }
    return self;
}

+ (Router *)sharedRouter {
    static Router *_sharedRouter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedRouter = [Router new];
    });
    
    return _sharedRouter;
}

#pragma marks - Defining Routes

- (void)addRoute:(NSString *)route handler:(RouteHandler)handler {
    self.routes[route] = handler;
}

- (void)addRoute:(NSString *)route forControllerClass:(Class)controllerClass {
    self.routes[route] = controllerClass;
}

- (void)removeRoute:(NSString *)route
{
    self.routes[route] = nil;
}

- (void)addRoutesWithDictionary:(NSDictionary *)routes {
    [routes enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        // if it's a class, make sure it's a subclass of UIViewController
        if (class_isMetaClass(object_getClass(obj))) {
            if (![obj isSubclassOfClass:[UIViewController class]]) {
                [NSException raise:@"Not a subclass of UIViewController" format:@"Must pass in either a subclass of UIViewController or handler block"];
            }
        }
        
        self.routes[key] = obj;
    }];
}

#pragma marks - Dispatching

- (UIViewController *)controllerForClass:(Class)cls params:(NSDictionary *)params {
    UIViewController *viewController = [cls new];
    [viewController applyRoutingParameters:params];
    return viewController;
}

/* DEPRICATED for iPad */
- (UIViewController *)controllerForHandlingURL:(NSURL *)url {
    __block UIViewController *viewController;
    [self matchURL:url matchHandler:^(NSDictionary *params, id classOrBlock) {
        if (class_isMetaClass(object_getClass(classOrBlock))) {
            viewController = [self controllerForClass:classOrBlock params:params];
        } else {
            UIViewController *(^blockForPath)(NSDictionary *, id) = classOrBlock;
            viewController = blockForPath(params, nil);
        }
    }];
    return viewController;
}

- (void)controllerForHandlingURL:(NSURL *)url handler:(ControllerHandler)handler {
    [self matchURL:url matchHandler:^(NSDictionary *params, id classOrBlock) {
        if (class_isMetaClass(object_getClass(classOrBlock))) { // it's a class
            UIViewController *returnedController = [self controllerForClass:classOrBlock params:params];
            handler(returnedController);
        } else {
            UIViewController *(^blockForPath)(NSDictionary *, id) = classOrBlock;
            UIViewController *returnedController = blockForPath(params, nil);
            handler(returnedController);
        }
    }];
}

#pragma marks - Primary iPad Routing Methods
- (UIViewController *)controllerForHandlingBlockFromURL:(NSURL *)url {
    __block UIViewController *returnedController;
    
    [self matchURL:url matchHandler:^(NSDictionary *params, id classOrBlock) {
        if (class_isMetaClass(object_getClass(classOrBlock))) { // it's a class
            returnedController = [self controllerForClass:classOrBlock params:params];
        } else {
            UIViewController *(^blockForPath)(NSDictionary *, id) = classOrBlock;
            returnedController = blockForPath(params, nil);
        }
    }];
    
    return returnedController;
}

- (UIViewController *)controllerForHandlingBlockFromViewModel:(CBIViewModel *)viewModel {
    __block id returnedController;
    NSURL *matchURL;
    if ([viewModel isKindOfClass:[CBISyllabusViewModel class]]){
        matchURL = [NSURL URLWithString:[viewModel.model.path stringByAppendingPathComponent:@"item/syllabus"]];
    }
    else {
        matchURL = [NSURL URLWithString:[viewModel.model.path realURLEncodedString]];
    }

    [self matchURL:matchURL matchHandler:^(NSDictionary *params, id classOrBlock) {
        if (class_isMetaClass(object_getClass(classOrBlock))) { // it's a class
            returnedController = [self controllerForClass:classOrBlock params:params];
        } else {
            id(^blockForPath)(NSDictionary *, id) = classOrBlock;
            returnedController = blockForPath(params, viewModel);
        }
    }];

    return returnedController;
}

- (UIViewController *)routeFromController:(UIViewController *)sourceController toURL:(NSURL *)url {

    UIViewController *destinationViewController = [self controllerForHandlingBlockFromURL:url];
    
    if (!destinationViewController && self.fallbackHandler) {
        self.fallbackHandler(url, sourceController);
        return nil;
    }

    [sourceController cbi_transitionToViewController:destinationViewController animated:YES];

    return destinationViewController;
}

- (UIViewController *)routeFromController:(UIViewController *)sourceController toViewModel:(CBIViewModel *)viewModel {
    
    UIViewController *destinationViewController = [self controllerForHandlingBlockFromViewModel:viewModel];
    
    [sourceController cbi_transitionToViewController:destinationViewController animated:YES];
    
    return destinationViewController;
}

- (void)openCanvasURL:(NSURL *)url {
    RACSignal *clientFromSuggestedDomain = [TheKeymaster signalForLoginWithDomain:url.host];
    
    [clientFromSuggestedDomain subscribeNext:^(CKIClient *client) {
        UIViewController *root = UIApplication.sharedApplication.windows[0].rootViewController;
        [self routeFromController:root.currentLeaf toURL:url];
    }];
}

# pragma marks - Parsing

- (NSDictionary *)parseURLQuery:(NSURL *)url
{
    NSMutableDictionary *queries = [NSMutableDictionary new];
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    [[components queryItems] enumerateObjectsUsingBlock:^(NSURLQueryItem * _Nonnull queryItem, NSUInteger idx, BOOL * _Nonnull stop) {
        queries[queryItem.name] = queryItem.value;
    }];
    return queries;
}

- (BOOL)matchURL:(NSURL *)url matchHandler:(void(^)(NSDictionary *params, id classOrBlock))matchHandler {
    NSString *path = url.path;
    path = [path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    path = [path stringByReplacingOccurrencesOfString:@"api/v1/" withString:@""];
    NSArray *urlComponents = path.pathComponents;
    
    __block NSURL *originalURL = url;
    __block NSMutableDictionary *params;
    __block BOOL matchFound = NO;
    
    [self.routes.allKeys enumerateObjectsUsingBlock:^(NSString *key, NSUInteger idx, BOOL *stop) {
        NSURL *routeURL = [NSURL URLWithString:key];
        NSArray *routeComponents = [routeURL.pathComponents subarrayWithRange:NSMakeRange(1, routeURL.pathComponents.count -1)];
        params = [NSMutableDictionary new];
        params[@"url"] = url;
        params[@"query"] = [self parseURLQuery:url];
        
        if (urlComponents.count != routeComponents.count) {
            return; // can't possibly match
        }
        
        for (NSUInteger i = 0; i < routeComponents.count; i++) {
            if ([routeComponents[i] hasPrefix:@":"]) { // save params in case this is a match
                NSString *paramKey = [routeComponents[i] substringFromIndex:1];
                NSString *param = urlComponents[i];
                NSNumber *number = [self.numberFormatter numberFromString:param];
                if (number) {
                    params[paramKey] = number;
                }
                else {
                    params[paramKey] = param;
                }
            }
            else if (![urlComponents[i] isEqualToString:routeComponents[i]]) {
                return; // not a match, continue to next key
            }
        }
        
        matchFound = YES;
        if (CKCanvasAPI.currentAPI) {
            params[@"canvasAPI"] = CKCanvasAPI.currentAPI;
        }
        if (params[@"courseIdent"]) {
            uint64_t ident = [params[@"courseIdent"] unsignedLongLongValue];
            params[@"contextInfo"] = [CKContextInfo contextInfoFromCourseIdent:ident];
        }
        else if (params[@"groupIdent"]) {
            uint64_t ident = [params[@"groupIdent"] unsignedLongLongValue];
            params[@"contextInfo"] = [CKContextInfo contextInfoFromGroupIdent:ident];
        }
        else if (params[@"userIdent"]) {
            uint64_t ident = [params[@"userIdent"] unsignedLongLongValue];
            params[@"contextInfo"] = [CKContextInfo contextInfoFromUserIdent:ident];
        }
        
        if ([self isDownloadURL:originalURL]) {
            params[@"downloadURL"] = originalURL;
        }
        
        matchHandler(params, self.routes[key]);
        *stop = matchFound;
    }];

    if(!matchFound){
        NSLog(@"no registered route for URL %@", url);
    }
    
    return matchFound;
}

- (BOOL) isDownloadURL:(NSURL *)url {
    NSArray *urlComponents = url.pathComponents;
    
    __block BOOL isDownload = NO;
    [urlComponents enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        if ([obj isEqualToString:@"download"]) {
            isDownload = YES;
            *stop = YES;
            return;
        }
    }];
    
    if (isDownload) {
        isDownload = [url.absoluteString.lowercaseString containsString:@"verifier"];
    }
    
    return isDownload;
}

@end
