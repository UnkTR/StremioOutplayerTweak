#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static const char *kDumpName = "stremio_player_dump.txt";
static BOOL gDumped = NO;

static NSString *Indent(int depth) {
    return [@"" stringByPaddingToLength:(NSUInteger)(depth * 2) withString:@" " startingAtIndex:0];
}

static NSString *DescribeObject(id obj) {
    if (!obj) return @"(nil)";
    return [NSString stringWithFormat:@"%@ <%p>", NSStringFromClass([obj class]), obj];
}

static void AppendTargetActions(NSMutableString *out, UIControl *control, NSString *prefix) {
    if (![control isKindOfClass:[UIControl class]]) return;
    for (id target in control.allTargets) {
        NSArray<NSString *> *actions = [control actionsForTarget:target forControlEvent:UIControlEventAllEvents];
        if (actions.count == 0) continue;
        [out appendFormat:@"%@  target=%@ actions=%@\n", prefix, DescribeObject(target), [actions componentsJoinedByString:@","]];
    }
}

static void AppendClassInfo(NSMutableString *out, Class cls, NSString *title) {
    if (!cls) return;
    [out appendFormat:@"\n=== %@: %@ ===\n", title, NSStringFromClass(cls)];
    Class current = cls;
    NSMutableArray<NSString *> *chain = [NSMutableArray array];
    while (current && current != [NSObject class]) {
        [chain addObject:NSStringFromClass(current)];
        current = class_getSuperclass(current);
    }
    [out appendFormat:@"superclasses=%@\n", [chain componentsJoinedByString:@" -> "]];

    unsigned int count = 0;
    objc_property_t *props = class_copyPropertyList(cls, &count);
    [out appendString:@"properties="];
    for (unsigned int i = 0; i < count; i++) {
        const char *name = property_getName(props[i]);
        if (i > 0) [out appendString:@", "];
        [out appendFormat:@"%s", name];
    }
    [out appendString:@"\n"];
    free(props);

    count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    [out appendString:@"methods="];
    for (unsigned int i = 0; i < count; i++) {
        const char *name = sel_getName(method_getName(methods[i]));
        if (i > 0) [out appendString:@", "];
        [out appendFormat:@"%s", name];
    }
    [out appendString:@"\n"];
    free(methods);
}

static NSString *DescribeView(UIView *view, int depth) {
    NSMutableString *s = [NSMutableString string];
    NSString *indent = Indent(depth);
    [s appendFormat:@"%@%@ frame=%@ hidden=%d alpha=%.2f tag=%ld clips=%d userInteraction=%d",
     indent,
     NSStringFromClass([view class]),
     NSStringFromCGRect(view.frame),
     view.hidden,
     view.alpha,
     (long)view.tag,
     view.clipsToBounds,
     view.userInteractionEnabled];

    if (view.accessibilityLabel.length > 0) [s appendFormat:@" axLabel=%@", view.accessibilityLabel];
    if (view.accessibilityIdentifier.length > 0) [s appendFormat:@" axId=%@", view.accessibilityIdentifier];
    if (view.accessibilityValue.length > 0) [s appendFormat:@" axValue=%@", view.accessibilityValue];

    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        [s appendFormat:@" text=%@ font=%@ size=%.1f color=%@ lines=%ld",
         label.text ?: @"",
         label.font.fontName ?: @"?",
         label.font.pointSize,
         label.textColor,
         (long)label.numberOfLines];
    } else if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        [s appendFormat:@" title=%@ hasImage=%d image=%@",
         [button titleForState:UIControlStateNormal] ?: @"",
         button.imageView.image != nil,
         button.imageView.image ? NSStringFromCGSize(button.imageView.image.size) : @"-"];
    } else if ([view isKindOfClass:[UISlider class]]) {
        UISlider *slider = (UISlider *)view;
        [s appendFormat:@" min=%.3f max=%.3f value=%.3f",
         slider.minimumValue, slider.maximumValue, slider.value];
    } else if ([view isKindOfClass:[UIStackView class]]) {
        UIStackView *stack = (UIStackView *)view;
        [s appendFormat:@" axis=%ld spacing=%.1f distribution=%ld alignment=%ld arranged=%lu",
         (long)stack.axis,
         stack.spacing,
         (long)stack.distribution,
         (long)stack.alignment,
         (unsigned long)stack.arrangedSubviews.count];
    } else if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *scroll = (UIScrollView *)view;
        [s appendFormat:@" contentOffset=%@ contentSize=%@",
         NSStringFromCGPoint(scroll.contentOffset),
         NSStringFromCGSize(scroll.contentSize)];
    }

    if ([view isKindOfClass:[UIControl class]]) {
        [s appendString:@"\n"];
        AppendTargetActions(s, (UIControl *)view, indent);
    } else {
        [s appendString:@"\n"];
    }

    for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
        [s appendFormat:@"%@  gesture=%@ enabled=%d state=%ld\n",
         indent, NSStringFromClass([gesture class]), gesture.enabled, (long)gesture.state];
    }

    for (UIView *subview in view.subviews) {
        [s appendString:DescribeView(subview, depth + 1)];
    }
    return s;
}

static UIView *FindControlsView(UIView *root) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count > 0) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSString *name = NSStringFromClass([view class]);
        if ([name containsString:@"VideoControlsView"]) {
            return view;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}

static void AppendKVC(NSMutableString *out, id object, NSArray<NSString *> *keys, NSString *prefix) {
    for (NSString *key in keys) {
        @try {
            id value = [object valueForKey:key];
            [out appendFormat:@"%@%@ = %@\n", prefix, key, DescribeObject(value)];
            if ([value isKindOfClass:[UIView class]]) {
                UIView *view = (UIView *)value;
                [out appendFormat:@"%@  frame=%@ hidden=%d alpha=%.2f\n",
                 prefix, NSStringFromCGRect(view.frame), view.hidden, view.alpha];
                if ([value isKindOfClass:[UISlider class]]) {
                    UISlider *slider = (UISlider *)value;
                    [out appendFormat:@"%@  slider min=%.3f max=%.3f value=%.3f\n",
                     prefix, slider.minimumValue, slider.maximumValue, slider.value];
                }
                if ([value isKindOfClass:[UIControl class]]) {
                    AppendTargetActions(out, (UIControl *)value, [prefix stringByAppendingString:@"  "]);
                }
            } else if ([value isKindOfClass:[NSNumber class]]) {
                [out appendFormat:@"%@  number=%@\n", prefix, value];
            } else if ([value isKindOfClass:[NSString class]]) {
                [out appendFormat:@"%@  string=%@\n", prefix, value];
            }
        } @catch (NSException *exception) {
            [out appendFormat:@"%@%@ = <KVC exception: %@>\n", prefix, key, exception.reason];
        }
    }
}

static void ShowToast(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                    if (candidate.isKeyWindow) {
                        window = candidate;
                        break;
                    }
                }
                if (window) break;
            }
        }
        if (!window) {
            window = UIApplication.sharedApplication.windows.firstObject;
        }
        if (!window) return;

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(16, 60, window.bounds.size.width - 32, 44)];
        label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.82];
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 2;
        label.layer.cornerRadius = 10;
        label.clipsToBounds = YES;
        label.text = message;
        [window addSubview:label];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [label removeFromSuperview];
        });
    });
}

static void DumpControls(UIView *fallbackRoot) {
    UIView *root = fallbackRoot;
    if (!root || !root.window) {
        UIWindow *window = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                    if (candidate.isKeyWindow) {
                        window = candidate;
                        break;
                    }
                }
                if (window) break;
            }
        }
        if (!window) {
            window = UIApplication.sharedApplication.windows.firstObject;
        }
        root = window.rootViewController.view ?: window;
    }
    if (!root) return;

    NSMutableString *out = [NSMutableString string];
    [out appendString:@"=== STREMIO PLAYER DUMP ===\n"];
    [out appendFormat:@"bundle=%@ version=%@\n",
     NSBundle.mainBundle.bundleIdentifier,
     [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]];
    [out appendString:@"\n=== FULL VIEW HIERARCHY ===\n"];
    [out appendString:DescribeView(root, 0)];

    UIView *controls = FindControlsView(root);
    [out appendFormat:@"\n=== CONTROLS VIEW: %@ ===\n", controls ? DescribeObject(controls) : @"NOT FOUND"];
    if (controls) {
        AppendClassInfo(out, [controls class], @"Controls class");

        NSArray<NSString *> *keys = @[
            @"playButton", @"nextButton", @"backButton", @"seekBar",
            @"currentTimeLabel", @"totalTimeLabel", @"controlsView", @"controlsStack",
            @"topControlsStack", @"controlsLeadingSpacer", @"controlsTrailingSpacer",
            @"aspectButton", @"fullScreenButton", @"pictureInPictureButton",
            @"speedButton", @"subtitlesButton", @"audioButton", @"detailedButton",
            @"airplayView", @"volumeControlView", @"gestureVolumeView", @"gestureSeekView",
            @"playerManager", @"currentTime", @"duration", @"isPlaying", @"isPaused",
            @"isPlayerReady", @"isFullScreen", @"usesDesktopLayout", @"videoControlsView",
            @"pendingSeekValue", @"seekTimeDuration", @"seekShortTimeDuration"
        ];
        AppendKVC(out, controls, keys, @"");

        id playerManager = nil;
        @try { playerManager = [controls valueForKey:@"playerManager"]; } @catch (NSException *exception) {}
        if (playerManager) {
            AppendClassInfo(out, [playerManager class], @"playerManager class");
            NSArray<NSString *> *pmKeys = @[
                @"currentTime", @"duration", @"isPlaying", @"isPaused", @"isPlayerReady",
                @"playbackRate", @"playbackState", @"player", @"playerView", @"playerController",
                @"videoControlsView", @"selectedSubtitleInfo", @"isPipSupported"
            ];
            AppendKVC(out, playerManager, pmKeys, @"pm.");
        }

        [out appendString:@"\n=== CONTROLS CONSTRAINTS ===\n"];
        for (NSLayoutConstraint *constraint in controls.constraints) {
            [out appendFormat:@"%@\n", constraint];
        }
        for (UIView *subview in controls.subviews) {
            [out appendFormat:@"\n-- constraints for %@ (%@) --\n", NSStringFromClass([subview class]), NSStringFromCGRect(subview.frame)];
            for (NSLayoutConstraint *constraint in subview.constraints) {
                [out appendFormat:@"%@\n", constraint];
            }
        }
    }

    NSString *documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *documentsPath = [documents stringByAppendingPathComponent:[NSString stringWithUTF8String:kDumpName]];
    NSError *error = nil;
    BOOL wrote = [out writeToFile:documentsPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
    NSString *tmpPath = [@"/tmp" stringByAppendingPathComponent:[NSString stringWithUTF8String:kDumpName]];
    [out writeToFile:tmpPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSLog(@"[OutplayerTweak] dump wrote=%d path=%@ error=%@ tmp=%@", wrote, documentsPath, error, tmpPath);
    ShowToast(wrote ? [NSString stringWithFormat:@"Player dump: %@", documentsPath] : @"Player dump could not be written");
}

static void ScheduleDump(UIView *view) {
    if (gDumped) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gDumped) return;
        gDumped = YES;
        DumpControls(view);
    });
}

static IMP gOriginalViewDidMoveToWindow = NULL;
static void HookViewDidMoveToWindow(id self, SEL _cmd) {
    if (gOriginalViewDidMoveToWindow) {
        ((void (*)(id, SEL))gOriginalViewDidMoveToWindow)(self, _cmd);
    }
    ScheduleDump((UIView *)self);
}

static IMP gOriginalViewDidAppear = NULL;
static void HookViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOriginalViewDidAppear) {
        ((void (*)(id, SEL, BOOL))gOriginalViewDidAppear)(self, _cmd, animated);
    }
    UIViewController *controller = (UIViewController *)self;
    ScheduleDump(controller.view);
}

static void InstallHook(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (!cls || !selector || !replacement) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    if (original) *original = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (!class_addMethod(cls, selector, replacement, types)) {
        Method ownMethod = class_getInstanceMethod(cls, selector);
        if (ownMethod) {
            method_setImplementation(ownMethod, replacement);
        }
    }
}

static Class FindStremioClass(NSString *needle) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return Nil;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!classes) return Nil;
    count = objc_getClassList(classes, count);
    Class found = Nil;
    for (int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if ([name containsString:@"Stremio"] && [name containsString:needle]) {
            found = classes[i];
            break;
        }
    }
    free(classes);
    return found;
}

__attribute__((constructor)) static void TweakInitialize(void) {
    NSLog(@"[OutplayerTweak] loaded");

    Class controlsClass = FindStremioClass(@"VideoControlsView");
    if (controlsClass) {
        InstallHook(controlsClass, @selector(viewDidMoveToWindow), (IMP)HookViewDidMoveToWindow, &gOriginalViewDidMoveToWindow);
        NSLog(@"[OutplayerTweak] hooked %@ viewDidMoveToWindow", NSStringFromClass(controlsClass));
    } else {
        NSLog(@"[OutplayerTweak] VideoControlsView not found");
    }

    Class playerClass = FindStremioClass(@"PlayerViewController");
    if (playerClass) {
        InstallHook(playerClass, @selector(viewDidAppear:), (IMP)HookViewDidAppear, &gOriginalViewDidAppear);
        NSLog(@"[OutplayerTweak] hooked %@ viewDidAppear:", NSStringFromClass(playerClass));
    } else {
        NSLog(@"[OutplayerTweak] PlayerViewController not found");
    }
}
