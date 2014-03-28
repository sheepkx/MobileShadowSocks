//
//  ProxyManager.m
//  MobileShadowSocks
//
//  Created by Linus Yang on 14-3-12.
//  Copyright (c) 2014 Linus Yang. All rights reserved.
//

#import "ProxyManager.h"
#import "ProfileManager.h"
#import <sys/types.h>
#import <sys/sysctl.h>

#define MAX_TRYTIMES 3
#define MAX_TIMEOUT 2.0
#define BOOT_TIME_DIFF 2

#define STR2(x) #x
#define STR(x) STR2(x)
#define MESSAGE_URL @"http://127.0.0.1:" STR(PAC_PORT) "/proxy.pac"

#define RESPONSE_SUCC @"Updated."
#define RESPONSE_FAIL @"Failed."

#define HEADER_VALUE @"True"
#define UPDATE_CONF @"Update-Conf"
#define FORCE_STOP @"Force-Stop"
#define SET_PROXY_PAC @"SetProxy-Pac"
#define SET_PROXY_SOCKS @"SetProxy-Socks"
#define SET_PROXY_NONE @"SetProxy-None"
#define SET_VPN_ALL @"SetVPN-All"
#define SET_VPN_AUTO @"SetVPN-Auto"
#define SET_VPN_NONE @"SetVPN-None"

typedef enum {
    kProxyOperationDisableProxy = 0,
    kProxyOperationEnableSocks,
    kProxyOperationEnablePac,
    kProxyOperationUpdateConf,
    kProxyOperationForceStop,
    kProxyOperationVPNRouteAll,
    kProxyOperationVPNRouteAuto,
    kProxyOperationVPNDisable,
    
    kProxyOperationCount
} ProxyOperation;

typedef enum {
    kProxyOperationSuccess = 0,
    kProxyOperationError
} ProxyOperationStatus;

@interface ProxyManager ()

@property (assign, nonatomic) UIBackgroundTaskIdentifier backgroundTask;

@end

@implementation ProxyManager

- (id)init
{
    self = [super init];
    if (self != nil) {
        if ([self isRebooted]) {
            [self _setPrefVPNModeEnabled:NO];
            [self resetBootTime];
        }
    }
    return self;
}

- (void)dealloc
{
    _delegate = nil;
    [super dealloc];
}

#pragma mark - Boot time checking

- (NSDate *)getBootTime
{
    int mib[2] = {CTL_KERN, KERN_BOOTTIME};
    struct timeval boottime;
    size_t size = sizeof(boottime);
    if (sysctl(mib, 2, &boottime, &size, NULL, 0) == 0) {
        return [NSDate dateWithTimeIntervalSince1970:boottime.tv_sec];
    }
    return nil;
}

- (BOOL)isRebooted
{
    NSDate *lastBootTime = [[ProfileManager sharedProfileManager] readObject:kProfileLastBootTime];
    if (lastBootTime == nil) {
        [self resetBootTime];
        return NO;
    }
    NSDate *nowBootTime = [self getBootTime];
    if (fabs([nowBootTime timeIntervalSinceDate:lastBootTime]) < BOOT_TIME_DIFF) {
        return NO;
    }
    return YES;
}

- (void)resetBootTime
{
    [[ProfileManager sharedProfileManager] saveObject:[self getBootTime] forKey:kProfileLastBootTime];
}

#pragma mark - Private methods

- (void)_setProxyEnabled:(BOOL)enabled showAlert:(BOOL)showAlert updateConf:(BOOL)isUpdateConf
{
    [self _setProxyEnabled:enabled showAlert:showAlert updateConf:isUpdateConf noSendOp:NO];
}

- (void)_setProxyEnabled:(BOOL)enabled showAlert:(BOOL)showAlert updateConf:(BOOL)isUpdateConf noSendOp:(BOOL)noSendOp
{
    BOOL isVPNMode = [self _prefVPNModeEnabled];
    BOOL isAutoProxy = [self _prefProxyAuto];

    // Set default operation to disable
    ProxyOperation op;
    if (isVPNMode) {
        op = kProxyOperationVPNDisable;
    } else {
        op = kProxyOperationDisableProxy;
    }
    
    // Check if enabling proxy
    if (enabled) {
        // Check if auto proxy is enabled
        if (isAutoProxy) {
            // Show alert if Pac file not found
            if (showAlert) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate checkFileNotFound];
                });
            }
            
            if (isVPNMode) {
                // Set operation to VPN auto routes
                op = kProxyOperationVPNRouteAuto;
            } else {
                // Set operation to Pac
                op = kProxyOperationEnablePac;
            }
        } else {
            if (isVPNMode) {
                // Set operation to VPN all routes
                op = kProxyOperationVPNRouteAll;
            } else {
                // Set operation to Socks
                op = kProxyOperationEnableSocks;
            }
        }

        // Update config only if proxy enabled
        if (isUpdateConf) {
            static BOOL firstUpdate = YES;
            static dispatch_once_t onceToken;
            
            // Only update when changed, except first time
            [self _sendProxyOperation:kProxyOperationUpdateConf updateOnlyChanged:!firstUpdate];
            dispatch_once(&onceToken, ^{
                firstUpdate = NO;
            });
        }
    }
    
    // Get current proxy operation
    ProxyOperation currentOp = [self _currentProxyOperation];
    
    // Execute proxy operation only if not same
    ProxyOperationStatus status = kProxyOperationSuccess;
    if (currentOp != op && !noSendOp) {
        status = [self _sendProxyOperation:op];
    }
    
    // Show alert when error
    if (status == kProxyOperationError) {
        if (isVPNMode) {
            // Alert error
            if (showAlert) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate showError:NSLocalizedString(@"Failed to change proxy settings in VPN Mode.\nPlease disable VPN Mode and retry.", nil)];
                });
            }
        } else {
            currentOp = [self _currentProxyOperation];
            isAutoProxy = (currentOp == kProxyOperationEnablePac);
            enabled = (currentOp == kProxyOperationEnablePac || currentOp == kProxyOperationEnableSocks);

            // Sync auto proxy settings
            [self _setPrefProxyAuto:isAutoProxy];

            // Alert error
            if (showAlert) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate showError:NSLocalizedString(@"Failed to change proxy settings.\nMaybe no network access available.", nil)];
                });
            }
        }
    }
    
    // save enable status
    [self _setPrefProxyEnabled:enabled];
    
    // Update UI
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate setBadge:enabled];
        [self.delegate setProxySwitcher:enabled];
        [self.delegate setAutoProxySwitcher:isAutoProxy];
    });
}

- (ProxyOperationStatus)_sendProxyOperation:(ProxyOperation)op
{
    return [self _sendProxyOperation:op updateOnlyChanged:NO];
}

- (ProxyOperationStatus)_sendProxyOperation:(ProxyOperation)op updateOnlyChanged:(BOOL)updateOnlyChanged
{
    ProxyOperationStatus ret = kProxyOperationError;
    NSString *messageHeader;
    
    // Get HTTP header field of operation
    switch (op) {
        case kProxyOperationUpdateConf:
            messageHeader = UPDATE_CONF;
            break;
        case kProxyOperationDisableProxy:
            messageHeader = SET_PROXY_NONE;
            break;
        case kProxyOperationEnableSocks:
            messageHeader = SET_PROXY_SOCKS;
            break;
        case kProxyOperationEnablePac:
            messageHeader = SET_PROXY_PAC;
            break;
        case kProxyOperationForceStop:
            messageHeader = FORCE_STOP;
            break;
        case kProxyOperationVPNDisable:
            messageHeader = SET_VPN_NONE;
            break;
        case kProxyOperationVPNRouteAll:
            messageHeader = SET_VPN_ALL;
            break;
        case kProxyOperationVPNRouteAuto:
            messageHeader = SET_VPN_AUTO;
            break;
        default:
            messageHeader = SET_PROXY_NONE;
            break;
    }
    
    // Sync config file
    BOOL isChanged = [[ProfileManager sharedProfileManager] syncSettings];

    // Update config only if file changed
    if (updateOnlyChanged && op == kProxyOperationUpdateConf && !isChanged) {
        return kProxyOperationSuccess;
    }
    
    // Init HTTP request
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:MESSAGE_URL]];
    [request setValue:HEADER_VALUE forHTTPHeaderField:messageHeader];
    [request setTimeoutInterval:MAX_TIMEOUT];
    
    // Try send request
    int i;
    for (i = 0; i < MAX_TRYTIMES; i++) {
        
        // Get response data
        NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:nil error:nil];
        
        // Continue if no response
        if (data == nil) {
            continue;
        }
        
        NSString *str = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        
        // Parse response
        if ([str hasPrefix:RESPONSE_SUCC]) {
            ret = kProxyOperationSuccess;
            break;
        } else if ([str hasPrefix:RESPONSE_FAIL]) {
            ret = kProxyOperationError;
            break;
        }
    }
    
    return ret;
}

- (ProxyOperation)_currentProxyOperation
{
    // Detect VPN mode
    if ([self _prefVPNModeEnabled]) {
        if ([self _prefProxyEnabled]) {
            // Reverse status deliberately to ensure always changing route settings
            if ([self _prefProxyAuto]) {
                return kProxyOperationVPNRouteAll;
            } else {
                return kProxyOperationVPNRouteAuto;
            }
        } else {
            return kProxyOperationVPNDisable;
        }
    }
    
    // Copy current status settings
    CFDictionaryRef proxyDict = CFNetworkCopySystemProxySettings();
    
    // Check if pac auto proxy enabled
    BOOL pacEnabled = [[(NSDictionary *) proxyDict objectForKey:@"ProxyAutoConfigEnable"] boolValue];
    
    // Check if socks proxy enabled
    BOOL socksEnabled = [[(NSDictionary *) proxyDict objectForKey:@"SOCKSEnable"] boolValue];
    
    // Determine current proxy operation
    ProxyOperation currentOp = kProxyOperationDisableProxy;
    if (pacEnabled) {
        currentOp = kProxyOperationEnablePac;
    } else if (socksEnabled) {
        currentOp = kProxyOperationEnableSocks;
    }
    
    // Clean up
    CFRelease(proxyDict);
    
    return currentOp;
}

- (BOOL)_prefProxyEnabled
{
    return [[ProfileManager sharedProfileManager] readBool:kProfileProxyEnabled];
}

- (BOOL)_prefProxyAuto
{
    return [[ProfileManager sharedProfileManager] readBool:kProfileAutoProxy];
}

- (BOOL)_prefVPNModeEnabled
{
    return [[ProfileManager sharedProfileManager] readBool:kProfileVPNMode];
}

- (void)_setPrefProxyEnabled:(BOOL)enabled
{
    [[ProfileManager sharedProfileManager] saveBool:enabled forKey:kProfileProxyEnabled];
}

- (void)_setPrefProxyAuto:(BOOL)enabled
{
    [[ProfileManager sharedProfileManager] saveBool:enabled forKey:kProfileAutoProxy];
}

- (void)_setPrefVPNModeEnabled:(BOOL)enabled
{
    [[ProfileManager sharedProfileManager] saveBool:enabled forKey:kProfileVPNMode];
}

- (void)_beginBackgroundTask
{
    self.backgroundTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        [self _endBackgroundTask];
    }];
}

- (void)_endBackgroundTask
{
    [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTask];
    self.backgroundTask = UIBackgroundTaskInvalid;
}

#pragma marks - Public methods

- (void)setProxyEnabled:(BOOL)enabled
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self _setProxyEnabled:enabled showAlert:YES updateConf:YES];
    });
}

- (void)setVPNModeEnabled:(BOOL)enabled
{
    // Enter VPN mode
    [self _setPrefVPNModeEnabled:YES];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL prefEnabled = [self _prefProxyEnabled];

        if (!enabled) {
            // Disable VPN routes
            [self _setProxyEnabled:NO showAlert:NO updateConf:YES];
            
            // Exit VPN mode
            [self _setPrefVPNModeEnabled:NO];
        }
        
        // Apply proxy settings
        if (prefEnabled) {
            [self _setProxyEnabled:YES showAlert:YES updateConf:YES];
        }
    });
}

- (void)syncAutoProxy
{
    // Change proxy only if proxy is enabled
    if ([self _prefProxyEnabled]) {
        [self setProxyEnabled:YES];
    }
}

- (void)syncProxyStatus:(BOOL)isForce
{
    BOOL prefEnabled = [self _prefProxyEnabled];
    
    // Sync when enabled or trying to proxy
    if (isForce || prefEnabled) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            // begin background task
            if (!isForce) {
                [self _beginBackgroundTask];
            }

            // No updating config when fixing proxy
            [self _setProxyEnabled:prefEnabled showAlert:isForce updateConf:!isForce noSendOp:[self _prefVPNModeEnabled]];

            // end background task
            if (!isForce) {
                [self _endBackgroundTask];
            }
        });
    }
}

- (void)forceStopProxyDaemon
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self _sendProxyOperation:kProxyOperationForceStop];
    });
}

@end
