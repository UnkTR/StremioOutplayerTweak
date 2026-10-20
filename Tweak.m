#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <MediaPlayer/MediaPlayer.h>
#import <math.h>

static char kSetupKey;
static char kTransportPillKey;
static char kProgressPillKey;
static char kPlayButtonKey;
static char kRewindButtonKey;
static char kForwardButtonKey;
static char kMoreButtonKey;
static char kBackButtonKey;
static char kSliderKey;
static char kCurrentLabelKey;
static char kTotalLabelKey;
static char kActionsKey;
static char kBottomBarKey;
static char kNextButtonKey;

static BOOL gOptimisticPlaying = YES;

typedef void (*VoidObjFn)(id, SEL, id);

static void CallVoidObj(id target, SEL selector, id argument) {
    if (!target || ![target respondsToSelector:selector]) return;
    ((VoidObjFn)objc_msgSend)(target, selector, argument);
}

static void InstallHook(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (!cls || !selector || !replacement) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    if (original) *original = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (!class_addMethod(cls, selector, replacement, types)) {
        Method ownMethod = class_getInstanceMethod(cls, selector);
        if (ownMethod) method_setImplementation(ownMethod, replacement);
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

static UIViewController *TopViewController(void) {
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
    if (!window) window = UIApplication.sharedApplication.windows.firstObject;
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    return controller;
}

static double ParseClockTime(NSString *text) {
    if (!text) return 0;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0 || [trimmed containsString:@"--"]) return 0;
    NSArray<NSString *> *parts = [trimmed componentsSeparatedByString:@":"];
    if (parts.count == 3) {
        return parts[0].doubleValue * 3600.0 + parts[1].doubleValue * 60.0 + parts[2].doubleValue;
    }
    if (parts.count == 2) {
        return parts[0].doubleValue * 60.0 + parts[1].doubleValue;
    }
    return trimmed.doubleValue;
}

static double CurrentDuration(UIView *controls) {
    UILabel *total = objc_getAssociatedObject(controls, &kTotalLabelKey);
    double duration = ParseClockTime(total.text);
    if (duration > 0) return duration;
    NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
    return [info[MPMediaItemPropertyPlaybackDuration] doubleValue];
}

static BOOL CurrentlyPlaying(void) {
    NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
    NSNumber *rate = info[MPNowPlayingInfoPropertyPlaybackRate];
    if (rate) return rate.doubleValue > 0.01;
    return gOptimisticPlaying;
}

static void UpdatePlayIcon(UIView *controls) {
    UIButton *playButton = objc_getAssociatedObject(controls, &kPlayButtonKey);
    if (!playButton) return;
    BOOL playing = CurrentlyPlaying();
    gOptimisticPlaying = playing;
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:30.0 weight:UIImageSymbolWeightSemibold];
    UIImage *image = [UIImage systemImageNamed:(playing ? @"pause.fill" : @"play.fill")
                             withConfiguration:configuration];
    [playButton setImage:image forState:UIControlStateNormal];
    playButton.tintColor = UIColor.whiteColor;
}

static void UpdatePlayIconSoon(UIView *controls) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UpdatePlayIcon(controls);
    });
}

static void SeekBy(UIView *controls, double seconds) {
    UISlider *slider = objc_getAssociatedObject(controls, &kSliderKey);
    if (!slider) return;
    double duration = CurrentDuration(controls);
    if (duration <= 0) return;
    double target = slider.value + (seconds / duration);
    target = MAX(0.0, MIN(1.0, target));
    if ([controls respondsToSelector:@selector(onSliderTouchDown:)]) {
        CallVoidObj(controls, @selector(onSliderTouchDown:), slider);
        slider.value = (float)target;
        CallVoidObj(controls, @selector(onSliderValChanged:), slider);
        CallVoidObj(controls, @selector(onSliderTouchUpInside:), slider);
    } else {
        [slider sendActionsForControlEvents:UIControlEventTouchDown];
        slider.value = (float)target;
        [slider sendActionsForControlEvents:UIControlEventValueChanged];
        [slider sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
}

static UIButton *FindButtonWithTitles(UIView *root, NSArray<NSString *> *titles) {
    for (UIView *view in root.subviews) {
        if ([view isKindOfClass:[UIButton class]]) {
            UIButton *button = (UIButton *)view;
            NSString *title = [button titleForState:UIControlStateNormal];
            if (title.length == 0) title = button.titleLabel.text;
            if (title.length > 0 && [titles containsObject:title]) return button;
        }
        UIButton *nested = FindButtonWithTitles(view, titles);
        if (nested) return nested;
    }
    return nil;
}

static void TriggerButton(UIView *controls, NSArray<NSString *> *titles) {
    UIButton *button = FindButtonWithTitles(controls, titles);
    if (button) [button sendActionsForControlEvents:UIControlEventTouchUpInside];
}

@interface OutplayerActions : NSObject
@property (nonatomic, weak) UIView *controls;
- (void)playTapped:(id)sender;
- (void)rewindTapped:(id)sender;
- (void)forwardTapped:(id)sender;
- (void)moreTapped:(UIButton *)sender;
@end

@implementation OutplayerActions

- (void)playTapped:(id)sender {
    gOptimisticPlaying = !gOptimisticPlaying;
    UpdatePlayIcon(self.controls);
    UpdatePlayIconSoon(self.controls);
}

- (void)rewindTapped:(id)sender {
    SeekBy(self.controls, -10.0);
}

- (void)forwardTapped:(id)sender {
    SeekBy(self.controls, 10.0);
}

- (void)moreTapped:(UIButton *)sender {
    UIView *controls = self.controls;
    if (!controls) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    void (^add)(NSString *, void (^)(void)) = ^(NSString *title, void (^handler)(void)) {
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            handler();
        }]];
    };
    add(@"Altyazılar", ^{
        TriggerButton(controls, @[@"Altyazılar", @"Subtitles"]);
        if (!FindButtonWithTitles(controls, @[@"Altyazılar", @"Subtitles"])) {
            CallVoidObj(controls, @selector(onSubtitleMenu:), sender);
        }
    });
    add(@"Ses İzleri", ^{
        TriggerButton(controls, @[@"Ses İzleri", @"Audio Tracks"]);
    });
    add(@"Oynatma Hızı", ^{
        TriggerButton(controls, @[@"Oynatma Hızı", @"Playback Speed"]);
    });
    add(@"PiP", ^{
        CallVoidObj(controls, @selector(onPipClicked:), sender);
    });
    add(@"En-Boy Oranı", ^{
        CallVoidObj(controls, @selector(onAspectButtonTap:), sender);
    });
    add(@"İstatistikler", ^{
        TriggerButton(controls, @[@"İstatistikler", @"Statistics"]);
        if (!FindButtonWithTitles(controls, @[@"İstatistikler", @"Statistics"])) {
            CallVoidObj(controls, @selector(onDebugClicked:), sender);
        }
    });
    add(@"Bölümler / Detaylar", ^{
        CallVoidObj(controls, @selector(onDetailedSidebarTap:), sender);
    });
    [sheet addAction:[UIAlertAction actionWithTitle:@"İptal" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sender;
    sheet.popoverPresentationController.sourceRect = sender.bounds;
    UIViewController *presenter = TopViewController();
    if (presenter) [presenter presentViewController:sheet animated:YES completion:nil];
}

@end

static UILabel *FindTimeLabel(UIView *controls, BOOL total) {
    UILabel *best = nil;
    CGFloat bestScore = CGFLOAT_MAX;
    CGFloat width = controls.bounds.size.width;
    for (UIView *view in controls.subviews) {
        if (![view isKindOfClass:[UILabel class]]) continue;
        if (view.bounds.size.width > 120.0) continue;
        CGFloat score = total ? fabs((width - view.frame.origin.x) - view.bounds.size.width)
                              : fabs(view.frame.origin.x);
        if (score < bestScore) {
            bestScore = score;
            best = (UILabel *)view;
        }
    }
    return best;
}

static void SetupOutplayerUI(UIView *controls) {
    if (objc_getAssociatedObject(controls, &kSetupKey)) return;

    UIButton *playButton = nil;
    UIButton *nextButton = nil;
    UIButton *backButton = nil;
    UISlider *slider = nil;
    UIView *bottomBar = nil;
    UIStackView *topRightStack = nil;
    UILabel *titleLabel = nil;

    for (UIView *view in controls.subviews) {
        if ([view isKindOfClass:[UIButton class]]) {
            UIButton *button = (UIButton *)view;
            if (button.bounds.size.width >= 60.0 && button.bounds.size.height >= 60.0) {
                if (button.alpha > 0.5 && !playButton) playButton = button;
                else if (button.alpha <= 0.5 && !nextButton) nextButton = button;
            } else if (button.bounds.size.width <= 40.0 && button.bounds.size.height <= 40.0 &&
                       button.frame.origin.y < 120.0 && !backButton) {
                backButton = button;
            }
        } else if ([view isKindOfClass:[UIStackView class]]) {
            if (view.frame.origin.x > controls.bounds.size.width - 120.0 && view.frame.origin.y < 120.0) {
                topRightStack = (UIStackView *)view;
            }
        } else if ([view isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)view;
            if (label.frame.origin.y < 120.0 && label.frame.origin.x > 50.0 && label.bounds.size.width > 100.0) {
                titleLabel = label;
            }
        }

        NSString *className = NSStringFromClass([view class]);
        if ([className containsString:@"ProgressSlider"] && [view isKindOfClass:[UISlider class]]) {
            slider = (UISlider *)view;
        }
        if ([view isKindOfClass:[UIView class]] && ![view isKindOfClass:[UIControl class]] &&
            ![view isKindOfClass:[UIStackView class]] && view.bounds.size.height >= 35.0 &&
            view.bounds.size.height <= 50.0 && view.frame.origin.y > controls.bounds.size.height - 120.0 &&
            view.bounds.size.width > controls.bounds.size.width * 0.75) {
            bottomBar = view;
        }
    }

    UILabel *currentLabel = FindTimeLabel(controls, NO);
    UILabel *totalLabel = FindTimeLabel(controls, YES);

    if (!playButton || !backButton || !slider || !currentLabel || !totalLabel) {
        return;
    }

    if (nextButton) nextButton.hidden = YES;
    if (bottomBar) bottomBar.hidden = YES;
    if (topRightStack) topRightStack.hidden = YES;
    if (titleLabel) titleLabel.hidden = YES;

    NSSet<UIView *> *movingViews = [NSSet setWithObjects:playButton, backButton, slider, currentLabel, totalLabel, nil];
    NSArray<NSLayoutConstraint *> *rootConstraints = [controls.constraints copy];
    for (NSLayoutConstraint *constraint in rootConstraints) {
        id first = constraint.firstItem;
        id second = constraint.secondItem;
        if ((first && [movingViews containsObject:first]) || (second && [movingViews containsObject:second])) {
            constraint.active = NO;
        }
    }
    for (UIView *view in movingViews) {
        NSArray<NSLayoutConstraint *> *constraints = [view.constraints copy];
        for (NSLayoutConstraint *constraint in constraints) {
            constraint.active = NO;
        }
        view.translatesAutoresizingMaskIntoConstraints = YES;
    }

    OutplayerActions *actions = [[OutplayerActions alloc] init];
    actions.controls = controls;
    objc_setAssociatedObject(controls, &kActionsKey, actions, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    backButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    backButton.layer.cornerRadius = 23.0;
    backButton.tintColor = UIColor.whiteColor;
    UIImageSymbolConfiguration *closeConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:17.0 weight:UIImageSymbolWeightSemibold];
    [backButton setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:closeConfiguration]
                forState:UIControlStateNormal];

    playButton.backgroundColor = UIColor.clearColor;
    playButton.tintColor = UIColor.whiteColor;
    [playButton addTarget:actions
                   action:@selector(playTapped:)
         forControlEvents:UIControlEventTouchUpInside];

    slider.minimumTrackTintColor = UIColor.whiteColor;
    slider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.28];
    slider.thumbTintColor = UIColor.whiteColor;
    slider.tintColor = UIColor.whiteColor;

    UIFont *timeFont = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightMedium];
    currentLabel.font = timeFont;
    currentLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
    currentLabel.textAlignment = NSTextAlignmentLeft;
    totalLabel.font = timeFont;
    totalLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
    totalLabel.textAlignment = NSTextAlignmentRight;

    UIView *transportPill = [[UIView alloc] initWithFrame:CGRectZero];
    transportPill.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.42];
    transportPill.layer.cornerRadius = 32.0;
    transportPill.layer.borderWidth = 0.5;
    transportPill.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
    transportPill.userInteractionEnabled = NO;
    [controls insertSubview:transportPill atIndex:0];

    UIView *progressPill = [[UIView alloc] initWithFrame:CGRectZero];
    progressPill.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.42];
    progressPill.layer.cornerRadius = 18.0;
    progressPill.layer.borderWidth = 0.5;
    progressPill.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
    progressPill.userInteractionEnabled = NO;
    [controls insertSubview:progressPill atIndex:1];

    UIImageSymbolConfiguration *skipConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:24.0 weight:UIImageSymbolWeightMedium];
    UIButton *rewindButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [rewindButton setImage:[UIImage systemImageNamed:@"gobackward.10" withConfiguration:skipConfiguration]
                  forState:UIControlStateNormal];
    rewindButton.tintColor = UIColor.whiteColor;
    [rewindButton addTarget:actions action:@selector(rewindTapped:) forControlEvents:UIControlEventTouchUpInside];
    [controls insertSubview:rewindButton atIndex:2];

    UIButton *forwardButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [forwardButton setImage:[UIImage systemImageNamed:@"goforward.10" withConfiguration:skipConfiguration]
                   forState:UIControlStateNormal];
    forwardButton.tintColor = UIColor.whiteColor;
    [forwardButton addTarget:actions action:@selector(forwardTapped:) forControlEvents:UIControlEventTouchUpInside];
    [controls insertSubview:forwardButton atIndex:3];

    UIButton *moreButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *moreConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:19.0 weight:UIImageSymbolWeightSemibold];
    [moreButton setImage:[UIImage systemImageNamed:@"ellipsis" withConfiguration:moreConfiguration]
                forState:UIControlStateNormal];
    moreButton.tintColor = UIColor.whiteColor;
    moreButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    moreButton.layer.cornerRadius = 23.0;
    [moreButton addTarget:actions action:@selector(moreTapped:) forControlEvents:UIControlEventTouchUpInside];
    [controls insertSubview:moreButton atIndex:4];

    objc_setAssociatedObject(controls, &kTransportPillKey, transportPill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kProgressPillKey, progressPill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kPlayButtonKey, playButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kRewindButtonKey, rewindButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kForwardButtonKey, forwardButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kMoreButtonKey, moreButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kBackButtonKey, backButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kSliderKey, slider, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kCurrentLabelKey, currentLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kTotalLabelKey, totalLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kBottomBarKey, bottomBar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kNextButtonKey, nextButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kSetupKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSLog(@"[OutplayerTweak] Outplayer UI installed on %@", NSStringFromClass([controls class]));
}

static void LayoutOutplayerUI(UIView *controls) {
    if (!objc_getAssociatedObject(controls, &kSetupKey)) return;

    UIButton *playButton = objc_getAssociatedObject(controls, &kPlayButtonKey);
    UIButton *rewindButton = objc_getAssociatedObject(controls, &kRewindButtonKey);
    UIButton *forwardButton = objc_getAssociatedObject(controls, &kForwardButtonKey);
    UIButton *moreButton = objc_getAssociatedObject(controls, &kMoreButtonKey);
    UIButton *backButton = objc_getAssociatedObject(controls, &kBackButtonKey);
    UIView *transportPill = objc_getAssociatedObject(controls, &kTransportPillKey);
    UIView *progressPill = objc_getAssociatedObject(controls, &kProgressPillKey);
    UISlider *slider = objc_getAssociatedObject(controls, &kSliderKey);
    UILabel *currentLabel = objc_getAssociatedObject(controls, &kCurrentLabelKey);
    UILabel *totalLabel = objc_getAssociatedObject(controls, &kTotalLabelKey);
    if (!playButton || !backButton || !slider || !currentLabel || !totalLabel) return;

    UIView *bottomBar = objc_getAssociatedObject(controls, &kBottomBarKey);
    UIButton *nextButton = objc_getAssociatedObject(controls, &kNextButtonKey);
    if (bottomBar) {
        bottomBar.hidden = YES;
        bottomBar.alpha = 0.0;
    }
    if (nextButton) nextButton.hidden = YES;

    UIEdgeInsets safeArea = controls.safeAreaInsets;
    CGFloat width = controls.bounds.size.width;
    CGFloat height = controls.bounds.size.height;
    CGFloat topMargin = safeArea.top + 16.0;
    CGFloat buttonSize = 46.0;

    backButton.frame = CGRectMake(20.0, topMargin, buttonSize, buttonSize);
    backButton.layer.cornerRadius = buttonSize / 2.0;
    moreButton.frame = CGRectMake(width - 20.0 - buttonSize, topMargin, buttonSize, buttonSize);
    moreButton.layer.cornerRadius = buttonSize / 2.0;

    CGFloat rowHeight = 64.0;
    CGFloat bottomY = height - safeArea.bottom - 20.0 - rowHeight;
    CGFloat transportWidth = 216.0;
    CGFloat gap = 12.0;

    if (width >= 700.0) {
        CGFloat progressWidth = MIN(560.0, width - 40.0 - transportWidth - gap);
        if (progressWidth < 260.0) progressWidth = width - 40.0 - transportWidth - gap;
        CGFloat totalWidth = transportWidth + gap + progressWidth;
        CGFloat startX = (width - totalWidth) / 2.0;
        transportPill.frame = CGRectMake(startX, bottomY, transportWidth, rowHeight);
        progressPill.frame = CGRectMake(startX + transportWidth + gap, bottomY, progressWidth, rowHeight);
    } else {
        CGFloat progressWidth = width - 40.0;
        progressPill.frame = CGRectMake(20.0, bottomY - rowHeight - 10.0, progressWidth, rowHeight);
        transportPill.frame = CGRectMake((width - transportWidth) / 2.0, bottomY, transportWidth, rowHeight);
    }

    rewindButton.frame = CGRectMake(CGRectGetMinX(transportPill.frame) + 12.0,
                                    CGRectGetMinY(transportPill.frame) + 8.0, 48.0, 48.0);
    playButton.frame = CGRectMake(CGRectGetMinX(transportPill.frame) + 84.0,
                                  CGRectGetMinY(transportPill.frame) + 6.0, 52.0, 52.0);
    forwardButton.frame = CGRectMake(CGRectGetMinX(transportPill.frame) + 156.0,
                                     CGRectGetMinY(transportPill.frame) + 8.0, 48.0, 48.0);

    CGFloat progressX = CGRectGetMinX(progressPill.frame);
    CGFloat progressY = CGRectGetMinY(progressPill.frame);
    CGFloat progressWidth = CGRectGetWidth(progressPill.frame);
    slider.frame = CGRectMake(progressX + 16.0, progressY + 9.0, progressWidth - 32.0, 30.0);
    currentLabel.frame = CGRectMake(progressX + 16.0, progressY + 40.0, 70.0, 16.0);
    totalLabel.frame = CGRectMake(progressX + progressWidth - 16.0 - 70.0, progressY + 40.0, 70.0, 16.0);

    // Keep Stremio's original auxiliary controls hidden without touching popups.
    for (UIView *view in controls.subviews) {
        if (view == backButton || view == moreButton || view == playButton ||
            view == rewindButton || view == forwardButton || view == slider ||
            view == currentLabel || view == totalLabel || view == transportPill ||
            view == progressPill) {
            continue;
        }
        if ([view isKindOfClass:[UIStackView class]] &&
            view.frame.origin.x > width - 120.0 && view.frame.origin.y < 120.0) {
            view.hidden = YES;
            view.alpha = 0.0;
        }
        if ([view isKindOfClass:[UILabel class]] &&
            view.frame.origin.y < 120.0 && view.frame.origin.x > 50.0 &&
            view.bounds.size.width > 100.0) {
            view.hidden = YES;
            view.alpha = 0.0;
        }
    }

    UpdatePlayIcon(controls);
}

static IMP gOriginalLayoutSubviews = NULL;
static void HookLayoutSubviews(id self, SEL _cmd) {
    if (gOriginalLayoutSubviews) {
        ((void (*)(id, SEL))gOriginalLayoutSubviews)(self, _cmd);
    }
    SetupOutplayerUI((UIView *)self);
    LayoutOutplayerUI((UIView *)self);
}

static IMP gOriginalShouldReceiveTouch = NULL;
static BOOL HookShouldReceiveTouch(id self, SEL _cmd, UIGestureRecognizer *gesture, UITouch *touch) {
    UIView *touchView = touch.view;
    if ([touchView isKindOfClass:[UIControl class]]) return NO;
    UIView *transportPill = objc_getAssociatedObject(self, &kTransportPillKey);
    UIView *progressPill = objc_getAssociatedObject(self, &kProgressPillKey);
    UIView *cursor = touchView;
    while (cursor) {
        if (cursor == transportPill || cursor == progressPill) return NO;
        cursor = cursor.superview;
    }
    if (gOriginalShouldReceiveTouch) {
        return ((BOOL (*)(id, SEL, UIGestureRecognizer *, UITouch *))gOriginalShouldReceiveTouch)(self, _cmd, gesture, touch);
    }
    return YES;
}

__attribute__((constructor)) static void TweakInitialize(void) {
    NSLog(@"[OutplayerTweak] loaded");
    Class controlsClass = FindStremioClass(@"VideoControlsView");
    if (!controlsClass) {
        NSLog(@"[OutplayerTweak] VideoControlsView not found");
        return;
    }
    InstallHook(controlsClass, @selector(layoutSubviews), (IMP)HookLayoutSubviews, &gOriginalLayoutSubviews);
    InstallHook(controlsClass, @selector(gestureRecognizer:shouldReceiveTouch:), (IMP)HookShouldReceiveTouch, &gOriginalShouldReceiveTouch);
    NSLog(@"[OutplayerTweak] hooked %@", NSStringFromClass(controlsClass));
}
