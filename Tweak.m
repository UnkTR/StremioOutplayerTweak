// Tweak.m - Outplayer-style player controls for Stremio iOS (embedded dylib, no jailbreak)
//
// Layout (landscape, measured from Outplayer screenshots, 1180x820 pt view):
//   top-left   : 45pt circle with X
//   top-right  : 45pt circle with playlist icon (opens Stremio episodes/details)
//   bottom row : [transport pill 154x43] [progress pill, flexible] [right pill 98x43]
//   popovers   : dark blurred rounded card, 348pt wide, anchored above the right pill

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <MediaPlayer/MediaPlayer.h>
#import <CoreText/CoreText.h>
#import <math.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/vm_prot.h>

static char kSetupKey;
static char kTransportPillKey;
static char kProgressPillKey;
static char kRightPillKey;
static char kTrackViewKey;
static char kFillViewKey;
static char kPlayButtonKey;
static char kRewindButtonKey;
static char kForwardButtonKey;
static char kQueueButtonKey;
static char kTracksButtonKey;
static char kSettingsButtonKey;
static char kBackButtonKey;
static char kSliderKey;
static char kCurrentLabelKey;
static char kTotalLabelKey;
static char kActionsKey;
static char kBottomBarKey;
static char kNextButtonKey;
static char kTimerKey;

static NSString *const kSkipIntervalDefaultsKey = @"OPSkipInterval";

static void LayoutOutplayerUI(UIView *controls);
static void SetupScrub(UIView *controls);
static void SetupTaps(UIView *controls);
static void UpdateSubtitlePresentation(UIView *controls);
static void HideControlsScrim(UIView *controls, NSArray<UIView *> *ours);
static UISlider *FindProgressSlider(UIView *root);

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

#pragma mark - Style helpers

static UIColor *PillColor(void) {
    // Outplayer's solid dark gray (#232325-ish).
    return [UIColor colorWithRed:0.137 green:0.137 blue:0.145 alpha:0.97];
}

// Outplayer uses Inter for all text. The .otf files are copied into the app
// bundle (OPFonts/) by the build workflow and registered here at launch.
static void RegisterInterFonts(void) {
    NSString *directory = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"OPFonts"];
    NSArray<NSString *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil];
    for (NSString *file in files) {
        if (![file.pathExtension.lowercaseString isEqualToString:@"otf"]) continue;
        NSURL *url = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:file]];
        CFErrorRef error = NULL;
        if (!CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &error)) {
            if (error) CFRelease(error);
        }
    }
}

static UIFont *InterFont(CGFloat size, UIFontWeight weight) {
    NSString *name = @"Inter-Regular";
    if (weight >= UIFontWeightBold) name = @"Inter-Bold";
    else if (weight >= UIFontWeightSemibold) name = @"Inter-SemiBold";
    else if (weight >= UIFontWeightMedium) name = @"Inter-Medium";
    UIFont *font = [UIFont fontWithName:name size:size];
    return font ?: [UIFont systemFontOfSize:size weight:weight];
}

// Inter with tabular (fixed-width) digits so running time labels do not jitter.
static UIFont *InterTabularFont(CGFloat size, UIFontWeight weight) {
    UIFont *font = InterFont(size, weight);
    NSDictionary *feature = @{UIFontFeatureTypeIdentifierKey: @(kNumberSpacingType),
                              UIFontFeatureSelectorIdentifierKey: @(kMonospacedNumbersSelector)};
    UIFontDescriptor *descriptor =
        [font.fontDescriptor fontDescriptorByAddingAttributes:@{UIFontDescriptorFeatureSettingsAttribute: @[feature]}];
    UIFont *tabular = [UIFont fontWithDescriptor:descriptor size:size];
    return tabular ?: font;
}

static UIImage *SymbolImage(NSArray<NSString *> *names, CGFloat size, UIImageSymbolWeight weight) {
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:size weight:weight];
    for (NSString *name in names) {
        UIImage *image = [UIImage systemImageNamed:name withConfiguration:configuration];
        if (image) {
            return [image imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        }
    }
    return nil;
}

static NSInteger SkipInterval(void) {
    NSInteger value = [NSUserDefaults.standardUserDefaults integerForKey:kSkipIntervalDefaultsKey];
    if (value != 5 && value != 10 && value != 15 && value != 30) value = 10;
    return value;
}

static UIImage *SkipImage(BOOL forward) {
    NSString *prefix = forward ? @"goforward" : @"gobackward";
    NSString *exact = [NSString stringWithFormat:@"%@.%ld", prefix, (long)SkipInterval()];
    NSString *fallback = [NSString stringWithFormat:@"%@.10", prefix];
    return SymbolImage(@[exact, fallback], 22.0, UIImageSymbolWeightRegular);
}

static void UpdateSkipIcons(UIView *controls) {
    UIButton *rewind = objc_getAssociatedObject(controls, &kRewindButtonKey);
    UIButton *forward = objc_getAssociatedObject(controls, &kForwardButtonKey);
    [rewind setImage:SkipImage(NO) forState:UIControlStateNormal];
    [forward setImage:SkipImage(YES) forState:UIControlStateNormal];
}

#pragma mark - Playback helpers

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

static double MaxClockInView(UIView *root) {
    if (!root) return 0;
    double best = 0;
    for (UIView *view in root.subviews) {
        if ([view isKindOfClass:[UILabel class]]) {
            NSString *text = ((UILabel *)view).text;
            if (text.length > 0 && [text rangeOfString:@":"].location != NSNotFound) {
                double value = ParseClockTime(text);
                if (value > best) best = value;
            }
        }
        double nested = MaxClockInView(view);
        if (nested > best) best = nested;
    }
    return best;
}

static double CurrentDuration(UIView *controls) {
    UILabel *total = objc_getAssociatedObject(controls, &kTotalLabelKey);
    double duration = ParseClockTime(total.text);
    if (duration > 0) return duration;

    // Stremio 2.1.0 reworked the controls; if the restyle bailed out we have no
    // label reference, so scrape the biggest clock string in the subtree.
    duration = MaxClockInView(controls);
    if (duration > 0) return duration;

    NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
    return [info[MPMediaItemPropertyPlaybackDuration] doubleValue];
}

static double SliderProgress(UISlider *slider) {
    if (!slider) return 0;
    double min = (double)slider.minimumValue;
    double max = (double)slider.maximumValue;
    if (!(max > min)) return (double)slider.value;
    double progress = ((double)slider.value - min) / (max - min);
    if (isnan(progress)) return 0;
    return MAX(0.0, MIN(1.0, progress));
}

static void SliderSetProgress(UISlider *slider, double progress) {
    if (!slider) return;
    if (isnan(progress)) progress = 0;
    progress = MAX(0.0, MIN(1.0, progress));
    double min = (double)slider.minimumValue;
    double max = (double)slider.maximumValue;
    if (!(max > min)) {
        slider.value = (float)progress;
        return;
    }
    slider.value = (float)(min + progress * (max - min));
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
    UIImage *image = SymbolImage(@[playing ? @"pause.fill" : @"play.fill"], 28.0, UIImageSymbolWeightMedium);
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
    if (!slider) slider = FindProgressSlider(controls);
    if (!slider) return;
    double duration = CurrentDuration(controls);
    if (duration <= 0) return;
    double target = SliderProgress(slider) + (seconds / duration);
    target = MAX(0.0, MIN(1.0, target));
    if ([controls respondsToSelector:@selector(onSliderTouchDown:)]) {
        CallVoidObj(controls, @selector(onSliderTouchDown:), slider);
        SliderSetProgress(slider, target);
        CallVoidObj(controls, @selector(onSliderValChanged:), slider);
        CallVoidObj(controls, @selector(onSliderTouchUpInside:), slider);
    } else {
        [slider sendActionsForControlEvents:UIControlEventTouchDown];
        SliderSetProgress(slider, target);
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
            NSString *label = button.accessibilityLabel;
            if (label.length > 0 && [titles containsObject:label]) return button;
        }
        UIButton *nested = FindButtonWithTitles(view, titles);
        if (nested) return nested;
    }
    return nil;
}

// Calls Stremio's own handler (the ObjC methods on VideoControlsView). If the
// method does not exist, falls back to firing the matching hidden button.
static void InvokeStremio(UIView *controls, SEL selector, NSArray<NSString *> *titles, id fallbackSender) {
    if (!controls) return;
    UIButton *button = titles.count > 0 ? FindButtonWithTitles(controls, titles) : nil;
    id sender = button ? (id)button : fallbackSender;
    if ([controls respondsToSelector:selector]) {
        CallVoidObj(controls, selector, sender);
    } else if (button) {
        [button sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
}

#pragma mark - Progress bar (custom thin bar drawn over the original slider)

static void UpdateProgress(UIView *controls) {
    UISlider *slider = objc_getAssociatedObject(controls, &kSliderKey);
    UIView *track = objc_getAssociatedObject(controls, &kTrackViewKey);
    UIView *fill = objc_getAssociatedObject(controls, &kFillViewKey);
    if (!slider || !track || !fill) return;

    // The original slider stays interactive but is practically invisible.
    if (slider.alpha != 0.02f) slider.alpha = 0.02f;

    float range = slider.maximumValue - slider.minimumValue;
    CGFloat progress = 0.0;
    if (range > 0.0001f) progress = (slider.value - slider.minimumValue) / range;
    if (isnan(progress)) progress = 0.0;
    progress = MAX(0.0, MIN(1.0, progress));

    CGRect bounds = track.bounds;
    fill.frame = CGRectMake(0.0, 0.0, bounds.size.width * progress, bounds.size.height);
}

#pragma mark - Popover rows

@interface OPRowButton : UIButton
@property (nonatomic, copy) void (^handler)(void);
@end

@implementation OPRowButton
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted ? [UIColor colorWithWhite:1.0 alpha:0.10] : UIColor.clearColor;
}
@end

@interface OutplayerActions : NSObject
@property (nonatomic, weak) UIView *controls;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIControl *catcher;
@property (nonatomic, assign) NSInteger panelKind;
- (void)playTapped:(id)sender;
- (void)rewindTapped:(id)sender;
- (void)forwardTapped:(id)sender;
- (void)queueTapped:(UIButton *)sender;
- (void)tracksTapped:(UIButton *)sender;
- (void)settingsTapped:(UIButton *)sender;
- (void)dismissPanel;
- (void)rowTapped:(OPRowButton *)sender;
- (void)skipChanged:(UISegmentedControl *)sender;
@end

static void PanelAddSection(UIView *content, CGFloat width, CGFloat *y, NSString *title) {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = title;
    label.font = InterFont(17.0, UIFontWeightSemibold);
    label.textColor = UIColor.whiteColor;
    [label sizeToFit];
    label.frame = CGRectMake(18.0, *y, label.bounds.size.width, 22.0);
    [content addSubview:label];

    CGFloat lineX = 18.0 + label.bounds.size.width + 10.0;
    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(lineX, *y + 11.0, MAX(0.0, width - 18.0 - lineX), 0.5)];
    line.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    [content addSubview:line];
    *y += 34.0;
}

static void PanelAddRow(UIView *content, CGFloat width, CGFloat *y, OutplayerActions *actions,
                        NSArray<NSString *> *iconNames, NSString *title, void (^handler)(void)) {
    OPRowButton *row = [OPRowButton buttonWithType:UIButtonTypeCustom];
    row.frame = CGRectMake(8.0, *y, width - 16.0, 48.0);
    row.layer.cornerRadius = 12.0;
    row.handler = handler;
    [row addTarget:actions action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIImageView *icon = [[UIImageView alloc] initWithImage:SymbolImage(iconNames, 19.0, UIImageSymbolWeightRegular)];
    icon.contentMode = UIViewContentModeCenter;
    icon.frame = CGRectMake(10.0, 10.0, 28.0, 28.0);
    icon.userInteractionEnabled = NO;
    [row addSubview:icon];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(48.0, 0.0, row.bounds.size.width - 48.0 - 36.0, 48.0)];
    label.text = title;
    label.font = InterFont(17.0, UIFontWeightMedium);
    label.textColor = UIColor.whiteColor;
    label.userInteractionEnabled = NO;
    [row addSubview:label];

    UIImageSymbolConfiguration *chevronConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightSemibold];
    UIImage *chevronImage = [[UIImage systemImageNamed:@"chevron.right" withConfiguration:chevronConfiguration]
        imageWithTintColor:[UIColor colorWithWhite:1.0 alpha:0.45]
             renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIImageView *chevron = [[UIImageView alloc] initWithImage:chevronImage];
    chevron.contentMode = UIViewContentModeCenter;
    chevron.frame = CGRectMake(row.bounds.size.width - 34.0, 12.0, 24.0, 24.0);
    chevron.userInteractionEnabled = NO;
    [row addSubview:chevron];

    [content addSubview:row];
    *y += 52.0;
}

static void PanelAddSkipRow(UIView *content, CGFloat width, CGFloat *y, OutplayerActions *actions) {
    UIImageView *icon = [[UIImageView alloc] initWithImage:SymbolImage(@[@"goforward", @"arrow.clockwise"], 19.0, UIImageSymbolWeightRegular)];
    icon.contentMode = UIViewContentModeCenter;
    icon.frame = CGRectMake(18.0, *y + 10.0, 28.0, 28.0);
    [content addSubview:icon];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(56.0, *y, 112.0, 48.0)];
    label.text = @"Atlama Süresi";
    label.font = InterFont(16.0, UIFontWeightMedium);
    label.textColor = UIColor.whiteColor;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.8;
    [content addSubview:label];

    UISegmentedControl *segmented = [[UISegmentedControl alloc] initWithItems:@[@"5", @"10", @"15", @"30"]];
    segmented.frame = CGRectMake(width - 18.0 - 156.0, *y + 7.0, 156.0, 34.0);
    segmented.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    segmented.selectedSegmentTintColor = UIColor.systemBlueColor;
    NSDictionary *textAttributes = @{NSForegroundColorAttributeName: UIColor.whiteColor,
                                     NSFontAttributeName: InterFont(15.0, UIFontWeightMedium)};
    [segmented setTitleTextAttributes:textAttributes forState:UIControlStateNormal];
    [segmented setTitleTextAttributes:textAttributes forState:UIControlStateSelected];
    NSInteger current = SkipInterval();
    segmented.selectedSegmentIndex = current == 5 ? 0 : (current == 10 ? 1 : (current == 15 ? 2 : 3));
    [segmented addTarget:actions action:@selector(skipChanged:) forControlEvents:UIControlEventValueChanged];
    [content addSubview:segmented];
    *y += 52.0;
}

@implementation OutplayerActions

- (void)dealloc {
    [self.panel removeFromSuperview];
    [self.catcher removeFromSuperview];
}

- (void)playTapped:(id)sender {
    gOptimisticPlaying = !gOptimisticPlaying;
    UpdatePlayIcon(self.controls);
    UpdatePlayIconSoon(self.controls);
}

- (void)rewindTapped:(id)sender {
    SeekBy(self.controls, -(double)SkipInterval());
}

- (void)forwardTapped:(id)sender {
    SeekBy(self.controls, (double)SkipInterval());
}

- (void)skipChanged:(UISegmentedControl *)sender {
    NSInteger values[4] = {5, 10, 15, 30};
    NSInteger index = sender.selectedSegmentIndex;
    if (index < 0 || index > 3) return;
    [NSUserDefaults.standardUserDefaults setInteger:values[index] forKey:kSkipIntervalDefaultsKey];
    if (self.controls) UpdateSkipIcons(self.controls);
}

- (void)dismissPanelAnimated:(BOOL)animated {
    UIView *card = self.panel;
    UIControl *catcher = self.catcher;
    self.panel = nil;
    self.catcher = nil;
    self.panelKind = 0;
    [catcher removeFromSuperview];
    if (!card) return;
    if (animated) {
        [UIView animateWithDuration:0.15 animations:^{
            card.alpha = 0.0;
        } completion:^(BOOL finished) {
            [card removeFromSuperview];
        }];
    } else {
        [card removeFromSuperview];
    }
}

- (void)dismissPanel {
    [self dismissPanelAnimated:YES];
}

- (void)rowTapped:(OPRowButton *)sender {
    void (^handler)(void) = sender.handler;
    [self dismissPanel];
    if (handler) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), handler);
    }
}

- (void)presentPanelOfKind:(NSInteger)kind builder:(CGFloat (^)(UIView *content, CGFloat width))builder {
    UIView *controls = self.controls;
    if (!controls) return;
    [self dismissPanelAnimated:NO];

    UIView *host = controls.superview ?: controls;
    UIView *rightPill = objc_getAssociatedObject(controls, &kRightPillKey);
    CGRect controlsInHost = [host convertRect:controls.bounds fromView:controls];
    CGRect pillInHost = rightPill ? [host convertRect:rightPill.frame fromView:controls]
                                  : CGRectMake(0.0, CGRectGetMaxY(controlsInHost) - 60.0, controlsInHost.size.width, 43.0);
    UIEdgeInsets safe = controls.safeAreaInsets;

    CGFloat cardWidth = MIN(348.0, controlsInHost.size.width - 24.0);
    CGFloat right = CGRectGetMaxX(controlsInHost) - MAX(safe.right, 0.0) - 11.0;
    CGFloat bottom = CGRectGetMaxY(pillInHost);
    CGFloat topLimit = CGRectGetMinY(controlsInHost) + safe.top + 12.0 + 45.0 + 12.0;
    CGFloat maxHeight = MAX(160.0, MIN(430.0, bottom - topLimit));

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    CGFloat contentHeight = builder(scroll, cardWidth);
    if (contentHeight <= 0.0) return;
    CGFloat cardHeight = MIN(contentHeight, maxHeight);

    UIVisualEffectView *card =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
    card.frame = CGRectMake(right - cardWidth, bottom - cardHeight, cardWidth, cardHeight);
    card.layer.cornerRadius = 26.0;
    card.clipsToBounds = YES;
    card.contentView.backgroundColor = [UIColor colorWithWhite:0.09 alpha:0.62];

    scroll.frame = card.contentView.bounds;
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scroll.contentSize = CGSizeMake(cardWidth, contentHeight);
    scroll.showsVerticalScrollIndicator = NO;
    scroll.alwaysBounceVertical = NO;
    [card.contentView addSubview:scroll];

    UIControl *catcher = [[UIControl alloc] initWithFrame:host.bounds];
    catcher.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    catcher.backgroundColor = UIColor.clearColor;
    [catcher addTarget:self action:@selector(dismissPanel) forControlEvents:UIControlEventTouchDown];

    [host addSubview:catcher];
    [host addSubview:card];
    card.alpha = 0.0;
    card.transform = CGAffineTransformMakeScale(0.96, 0.96);
    [UIView animateWithDuration:0.18 animations:^{
        card.alpha = 1.0;
        card.transform = CGAffineTransformIdentity;
    }];

    self.panel = card;
    self.catcher = catcher;
    self.panelKind = kind;
}

// Top-right: Stremio's episodes / details sidebar.
- (void)queueTapped:(UIButton *)sender {
    [self dismissPanelAnimated:NO];
    InvokeStremio(self.controls, @selector(onDetailedSidebarTap:), nil, sender);
}

// Bottom-right, right icon: audio / subtitle tracks.
- (void)tracksTapped:(UIButton *)sender {
    if (self.panel && self.panelKind == 1) {
        [self dismissPanel];
        return;
    }
    __weak OutplayerActions *weakSelf = self;
    __weak UIButton *anchor = sender;
    [self presentPanelOfKind:1 builder:^CGFloat(UIView *content, CGFloat width) {
        OutplayerActions *strongSelf = weakSelf;
        if (!strongSelf) return 0.0;
        CGFloat y = 16.0;
        PanelAddSection(content, width, &y, @"Ses");
        PanelAddRow(content, width, &y, strongSelf, @[@"speaker.wave.2", @"speaker.wave.2.fill"], @"Ses İzleri", ^{
            InvokeStremio(weakSelf.controls, @selector(onAudioTrackSelect:), @[@"Ses İzleri", @"Audio Tracks", @"Audio"], anchor);
        });
        y += 6.0;
        PanelAddSection(content, width, &y, @"Altyazılar");
        PanelAddRow(content, width, &y, strongSelf, @[@"captions.bubble", @"text.bubble"], @"Altyazılar", ^{
            InvokeStremio(weakSelf.controls, @selector(onSubtitleMenu:), @[@"Altyazılar", @"Subtitles"], anchor);
        });
        return y + 12.0;
    }];
}

// Bottom-right, left icon: playback / video / interface settings.
- (void)settingsTapped:(UIButton *)sender {
    if (self.panel && self.panelKind == 2) {
        [self dismissPanel];
        return;
    }
    __weak OutplayerActions *weakSelf = self;
    __weak UIButton *anchor = sender;
    [self presentPanelOfKind:2 builder:^CGFloat(UIView *content, CGFloat width) {
        OutplayerActions *strongSelf = weakSelf;
        if (!strongSelf) return 0.0;
        CGFloat y = 16.0;
        PanelAddSection(content, width, &y, @"Oynatma");
        PanelAddRow(content, width, &y, strongSelf, @[@"speedometer", @"gauge"], @"Oynatma Hızı", ^{
            InvokeStremio(weakSelf.controls, @selector(onPlaybackButton:), @[@"Oynatma Hızı", @"Playback Speed"], anchor);
        });
        PanelAddRow(content, width, &y, strongSelf, @[@"forward.end.fill", @"forward.end"], @"Sonraki Bölüm", ^{
            InvokeStremio(weakSelf.controls, @selector(onNextButtonTap:), nil, anchor);
        });
        y += 6.0;
        PanelAddSection(content, width, &y, @"Video");
        PanelAddRow(content, width, &y, strongSelf, @[@"aspectratio", @"rectangle.expand.vertical"], @"En-Boy Oranı", ^{
            InvokeStremio(weakSelf.controls, @selector(onAspectButtonTap:), nil, anchor);
        });
        PanelAddRow(content, width, &y, strongSelf, @[@"pip", @"pip.enter"], @"Resim İçinde Resim", ^{
            InvokeStremio(weakSelf.controls, @selector(onPipClicked:), nil, anchor);
        });
        PanelAddRow(content, width, &y, strongSelf, @[@"chart.bar", @"info.circle"], @"İstatistikler", ^{
            InvokeStremio(weakSelf.controls, @selector(onDebugClicked:), @[@"İstatistikler", @"Statistics"], anchor);
        });
        y += 6.0;
        PanelAddSection(content, width, &y, @"Arayüz");
        PanelAddSkipRow(content, width, &y, strongSelf);
        return y + 12.0;
    }];
}

@end

#pragma mark - View discovery

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

static BOOL IsStremioPopupView(UIView *view) {
    NSString *name = NSStringFromClass([view class]);
    return [name containsString:@"Episodes"] || [name containsString:@"Popup"] ||
           [name containsString:@"P2P"] || [name containsString:@"Peer"];
}

// Keeps our views above Stremio's own overlays (gradients, gesture views) but
// below its popups, without reordering when nothing changed.
static void EnsureZOrder(UIView *controls, NSArray<UIView *> *ours) {
    NSArray<UIView *> *subviews = controls.subviews;
    BOOL ordered = YES;
    BOOL first = YES;
    NSUInteger firstIndex = 0;
    NSUInteger previous = 0;
    for (UIView *view in ours) {
        NSUInteger index = [subviews indexOfObject:view];
        if (index == NSNotFound) return;
        if (first) {
            firstIndex = index;
            first = NO;
        } else if (index <= previous) {
            ordered = NO;
        }
        previous = index;
    }
    if (ordered) {
        for (NSUInteger i = firstIndex; i < subviews.count; i++) {
            UIView *view = subviews[i];
            if (![ours containsObject:view] && !IsStremioPopupView(view)) {
                ordered = NO;
                break;
            }
        }
    }
    if (ordered) return;
    for (UIView *view in ours) [controls bringSubviewToFront:view];
    for (UIView *view in [controls.subviews copy]) {
        if (IsStremioPopupView(view)) [controls bringSubviewToFront:view];
    }
}

#pragma mark - Setup

static UIButton *MakeIconButton(UIImage *image, NSString *accessibilityLabel) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setImage:image forState:UIControlStateNormal];
    button.accessibilityLabel = accessibilityLabel;
    return button;
}

static UIView *MakePill(void) {
    UIView *pill = [[UIView alloc] initWithFrame:CGRectZero];
    pill.backgroundColor = PillColor();
    pill.userInteractionEnabled = NO;
    return pill;
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

    // Top-left: X
    backButton.backgroundColor = PillColor();
    backButton.tintColor = UIColor.whiteColor;
    backButton.accessibilityLabel = @"Kapat";
    [backButton setImage:SymbolImage(@[@"xmark"], 19.0, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];

    // Play / pause (Stremio's own button, restyled)
    playButton.backgroundColor = UIColor.clearColor;
    playButton.tintColor = UIColor.whiteColor;
    [playButton addTarget:actions action:@selector(playTapped:) forControlEvents:UIControlEventTouchUpInside];

    // Original slider: stays interactive, but invisible; we draw a thin bar instead.
    slider.alpha = 0.02;

    UIFont *timeFont = InterTabularFont(17.0, UIFontWeightRegular);
    currentLabel.font = timeFont;
    currentLabel.textColor = UIColor.whiteColor;
    currentLabel.textAlignment = NSTextAlignmentLeft;
    totalLabel.font = timeFont;
    totalLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    totalLabel.textAlignment = NSTextAlignmentRight;

    UIView *transportPill = MakePill();
    UIView *progressPill = MakePill();
    UIView *rightPill = MakePill();
    [controls addSubview:transportPill];
    [controls addSubview:progressPill];
    [controls addSubview:rightPill];

    UIView *track = [[UIView alloc] initWithFrame:CGRectZero];
    track.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.20];
    track.layer.cornerRadius = 3.0;
    track.clipsToBounds = YES;
    track.userInteractionEnabled = NO;
    UIView *fill = [[UIView alloc] initWithFrame:CGRectZero];
    fill.backgroundColor = UIColor.whiteColor;
    fill.userInteractionEnabled = NO;
    [track addSubview:fill];
    [controls addSubview:track];

    UIButton *rewindButton = MakeIconButton(SkipImage(NO), @"Geri sar");
    [rewindButton addTarget:actions action:@selector(rewindTapped:) forControlEvents:UIControlEventTouchUpInside];
    [controls addSubview:rewindButton];

    UIButton *forwardButton = MakeIconButton(SkipImage(YES), @"İleri sar");
    [forwardButton addTarget:actions action:@selector(forwardTapped:) forControlEvents:UIControlEventTouchUpInside];
    [controls addSubview:forwardButton];

    UIButton *settingsButton = MakeIconButton(
        SymbolImage(@[@"switch.2", @"slider.horizontal.3"], 21.0, UIImageSymbolWeightMedium), @"Ayarlar");
    [settingsButton addTarget:actions action:@selector(settingsTapped:) forControlEvents:UIControlEventTouchUpInside];
    [controls addSubview:settingsButton];

    UIButton *tracksButton = MakeIconButton(
        SymbolImage(@[@"list.bullet"], 21.0, UIImageSymbolWeightMedium), @"Ses ve altyazı");
    [tracksButton addTarget:actions action:@selector(tracksTapped:) forControlEvents:UIControlEventTouchUpInside];
    [controls addSubview:tracksButton];

    UIButton *queueButton = MakeIconButton(
        SymbolImage(@[@"play.square.stack", @"rectangle.stack"], 21.0, UIImageSymbolWeightMedium), @"Bölümler");
    queueButton.backgroundColor = PillColor();
    [queueButton addTarget:actions action:@selector(queueTapped:) forControlEvents:UIControlEventTouchUpInside];
    [controls addSubview:queueButton];

    objc_setAssociatedObject(controls, &kTransportPillKey, transportPill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kProgressPillKey, progressPill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kRightPillKey, rightPill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kTrackViewKey, track, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kFillViewKey, fill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kPlayButtonKey, playButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kRewindButtonKey, rewindButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kForwardButtonKey, forwardButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kQueueButtonKey, queueButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kTracksButtonKey, tracksButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kSettingsButtonKey, settingsButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kBackButtonKey, backButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kSliderKey, slider, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kCurrentLabelKey, currentLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kTotalLabelKey, totalLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kBottomBarKey, bottomBar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kNextButtonKey, nextButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kSetupKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 10 Hz tick keeps the thin bar in sync (also while dragging); every 5th
    // tick re-applies the full layout so Stremio cannot bring its controls back.
    __weak UIView *weakControls = controls;
    __block NSInteger tick = 0;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *currentTimer) {
        UIView *strongControls = weakControls;
        if (!strongControls) {
            [currentTimer invalidate];
            return;
        }
        tick++;
        if (tick % 5 == 0) {
            LayoutOutplayerUI(strongControls);
        } else {
            UpdateProgress(strongControls);
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    objc_setAssociatedObject(controls, &kTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    SetupScrub(controls);
    SetupTaps(controls);

    NSLog(@"[OutplayerTweak] Outplayer UI installed on %@", NSStringFromClass([controls class]));
}

#pragma mark - Layout

static void LayoutOutplayerUI(UIView *controls) {
    if (!objc_getAssociatedObject(controls, &kSetupKey)) return;

    UIButton *playButton = objc_getAssociatedObject(controls, &kPlayButtonKey);
    UIButton *rewindButton = objc_getAssociatedObject(controls, &kRewindButtonKey);
    UIButton *forwardButton = objc_getAssociatedObject(controls, &kForwardButtonKey);
    UIButton *queueButton = objc_getAssociatedObject(controls, &kQueueButtonKey);
    UIButton *tracksButton = objc_getAssociatedObject(controls, &kTracksButtonKey);
    UIButton *settingsButton = objc_getAssociatedObject(controls, &kSettingsButtonKey);
    UIButton *backButton = objc_getAssociatedObject(controls, &kBackButtonKey);
    UIView *transportPill = objc_getAssociatedObject(controls, &kTransportPillKey);
    UIView *progressPill = objc_getAssociatedObject(controls, &kProgressPillKey);
    UIView *rightPill = objc_getAssociatedObject(controls, &kRightPillKey);
    UIView *track = objc_getAssociatedObject(controls, &kTrackViewKey);
    UISlider *slider = objc_getAssociatedObject(controls, &kSliderKey);
    UILabel *currentLabel = objc_getAssociatedObject(controls, &kCurrentLabelKey);
    UILabel *totalLabel = objc_getAssociatedObject(controls, &kTotalLabelKey);
    if (!playButton || !rewindButton || !forwardButton || !queueButton || !tracksButton || !settingsButton ||
        !backButton || !transportPill || !progressPill || !rightPill || !track || !slider ||
        !currentLabel || !totalLabel) {
        return;
    }

    UIView *bottomBar = objc_getAssociatedObject(controls, &kBottomBarKey);
    UIButton *nextButton = objc_getAssociatedObject(controls, &kNextButtonKey);
    if (bottomBar) {
        bottomBar.hidden = YES;
        bottomBar.alpha = 0.0;
    }
    if (nextButton) nextButton.hidden = YES;

    UIEdgeInsets safe = controls.safeAreaInsets;
    CGFloat width = controls.bounds.size.width;
    CGFloat height = controls.bounds.size.height;
    BOOL wide = width >= 700.0;

    // Top buttons
    CGFloat circle = 45.0;
    CGFloat topY = safe.top + 12.0;
    CGFloat leftEdge = MAX(safe.left, 0.0) + 20.0;
    CGFloat rightEdge = width - MAX(safe.right, 0.0) - 20.0;
    backButton.frame = CGRectMake(leftEdge, topY, circle, circle);
    backButton.layer.cornerRadius = circle / 2.0;
    queueButton.frame = CGRectMake(rightEdge - circle, topY, circle, circle);
    queueButton.layer.cornerRadius = circle / 2.0;

    // Bottom row
    CGFloat rowHeight = 43.0;
    CGFloat transportWidth = 154.0;
    CGFloat rightWidth = 98.0;
    CGFloat gap = 16.0;
    CGFloat rowY = height - safe.bottom - 13.0 - rowHeight;
    CGRect transportFrame;
    CGRect rightFrame;
    CGRect progressFrame;
    if (wide) {
        CGFloat x0 = MAX(60.0, MAX(safe.left, 0.0) + 20.0);
        CGFloat x1 = width - MAX(60.0, MAX(safe.right, 0.0) + 20.0);
        transportFrame = CGRectMake(x0, rowY, transportWidth, rowHeight);
        rightFrame = CGRectMake(x1 - rightWidth, rowY, rightWidth, rowHeight);
        CGFloat progressX = x0 + transportWidth + gap;
        CGFloat progressRight = x1 - rightWidth - gap;
        progressFrame = CGRectMake(progressX, rowY, MAX(200.0, progressRight - progressX), rowHeight);
    } else {
        transportFrame = CGRectMake(leftEdge, rowY, transportWidth, rowHeight);
        rightFrame = CGRectMake(rightEdge - rightWidth, rowY, rightWidth, rowHeight);
        progressFrame = CGRectMake(leftEdge, rowY - rowHeight - 12.0, rightEdge - leftEdge, rowHeight);
    }

    transportPill.frame = transportFrame;
    transportPill.layer.cornerRadius = rowHeight / 2.0;
    progressPill.frame = progressFrame;
    progressPill.layer.cornerRadius = rowHeight / 2.0;
    rightPill.frame = rightFrame;
    rightPill.layer.cornerRadius = rowHeight / 2.0;

    CGFloat tx = CGRectGetMinX(transportFrame);
    CGFloat ty = CGRectGetMinY(transportFrame);
    rewindButton.frame = CGRectMake(tx, ty, 46.0, rowHeight);
    playButton.frame = CGRectMake(tx + 54.0, ty, 46.0, rowHeight);
    forwardButton.frame = CGRectMake(tx + 108.0, ty, 46.0, rowHeight);

    CGFloat rx = CGRectGetMinX(rightFrame);
    CGFloat ry = CGRectGetMinY(rightFrame);
    settingsButton.frame = CGRectMake(rx, ry, rightWidth / 2.0, rowHeight);
    tracksButton.frame = CGRectMake(rx + rightWidth / 2.0, ry, rightWidth / 2.0, rowHeight);

    // Progress pill: [0:00] ---thin bar--- [total]
    CGFloat px = CGRectGetMinX(progressFrame);
    CGFloat py = CGRectGetMinY(progressFrame);
    CGFloat pw = CGRectGetWidth(progressFrame);
    CGFloat labelWidth = 72.0;
    CGFloat labelHeight = 22.0;
    CGFloat labelY = py + (rowHeight - labelHeight) / 2.0;
    currentLabel.frame = CGRectMake(px + 22.0, labelY, labelWidth, labelHeight);
    totalLabel.frame = CGRectMake(px + pw - 22.0 - labelWidth, labelY, labelWidth, labelHeight);

    CGFloat barX = px + 22.0 + labelWidth + 4.0;
    CGFloat barWidth = MAX(40.0, pw - 2.0 * (22.0 + labelWidth + 4.0));
    CGFloat barHeight = 6.0;
    track.frame = CGRectMake(barX, py + (rowHeight - barHeight) / 2.0, barWidth, barHeight);

    // The hidden original slider reaches ~18pt past the bar on each side so the
    // (invisible) Liquid Glass thumb lines up with our bar ends.
    CGFloat sliderInset = 18.0;
    slider.frame = CGRectMake(barX - sliderInset, py + (rowHeight - 36.0) / 2.0, barWidth + 2.0 * sliderInset, 36.0);

    // Keep Stremio's original auxiliary controls hidden without touching popups.
    NSArray<UIView *> *ours = @[transportPill, progressPill, rightPill, track, rewindButton, forwardButton,
                                playButton, settingsButton, tracksButton, queueButton, backButton,
                                currentLabel, totalLabel, slider];
    for (UIView *view in controls.subviews) {
        if ([ours containsObject:view]) continue;
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

    EnsureZOrder(controls, ours);
    HideControlsScrim(controls, ours);
    UpdateProgress(controls);
    UpdatePlayIcon(controls);
}

static UISlider *FindProgressSlider(UIView *root) {
    if (!root) return nil;
    for (UIView *view in root.subviews) {
        if ([view isKindOfClass:[UISlider class]] &&
            [NSStringFromClass([view class]) containsString:@"ProgressSlider"]) {
            return (UISlider *)view;
        }
        UISlider *nested = FindProgressSlider(view);
        if (nested) return nested;
    }
    return nil;
}

#pragma mark - Swipe to scrub (Outplayer style)

static char kScrubberKey;
static char kTapperKey;
// Full screen width of dragging == this fraction of the total duration.
// Smaller = finer control. 0.5 on a 2 hour movie -> ~3 s per point on a 1180 pt iPad.
static const double kScrubSpanFraction = 0.5;

// m:ss under one hour, h:mm:ss above it (matches the Outplayer HUD).
static NSString *FormatClock(double seconds) {
    if (!isfinite(seconds) || seconds < 0) seconds = 0;
    long long total = (long long)llround(seconds);
    long long h = total / 3600;
    long long m = (total % 3600) / 60;
    long long s = total % 60;
    if (h > 0) return [NSString stringWithFormat:@"%lld:%02lld:%02lld", h, m, s];
    return [NSString stringWithFormat:@"%lld:%02lld", m, s];
}

static CGFloat MeasuredWidth(NSString *text, UIFont *font) {
    if (text.length == 0 || !font) return 0.0;
    CGRect rect = [text boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                     options:NSStringDrawingUsesLineFragmentOrigin
                                  attributes:@{NSFontAttributeName: font}
                                     context:nil];
    return ceil(rect.size.width);
}

// Cached lookup of Stremio's progress slider, with a lazy fallback because the
// 2.1.0 layout can rebuild (and reparent) the controls at any time.
static UISlider *CachedSlider(UIView *controls) {
    if (!controls) return nil;
    UISlider *slider = objc_getAssociatedObject(controls, &kSliderKey);
    if (slider && slider.window) return slider;
    UISlider *found = FindProgressSlider(controls);
    if (found) {
        objc_setAssociatedObject(controls, &kSliderKey, found, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return found;
    }
    return slider;
}

#pragma mark - Progress bar colour (white fill, dim track, white thumb)

static char kWhiteTrackImageKey;

// Stremio's accent colour is a violet; anything clearly blue-dominant is it.
static BOOL ColorIsAccentPurple(UIColor *color) {
    if (!color) return NO;
    CGFloat r = 0.0, g = 0.0, b = 0.0, a = 0.0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) return NO;
    if (a < 0.05) return NO;
    return (b > r + 0.10) && (b > g + 0.10);
}

static void RecolorPurpleLayers(CALayer *layer, NSInteger depth) {
    if (!layer || depth < 0) return;

    if (layer.backgroundColor) {
        UIColor *color = [UIColor colorWithCGColor:layer.backgroundColor];
        if (ColorIsAccentPurple(color)) layer.backgroundColor = UIColor.whiteColor.CGColor;
    }
    if (layer.borderColor) {
        UIColor *color = [UIColor colorWithCGColor:layer.borderColor];
        if (ColorIsAccentPurple(color)) layer.borderColor = UIColor.whiteColor.CGColor;
    }
    if ([layer isKindOfClass:[CAShapeLayer class]]) {
        CAShapeLayer *shape = (CAShapeLayer *)layer;
        if (shape.strokeColor && ColorIsAccentPurple([UIColor colorWithCGColor:shape.strokeColor])) {
            shape.strokeColor = UIColor.whiteColor.CGColor;
        }
        if (shape.fillColor && ColorIsAccentPurple([UIColor colorWithCGColor:shape.fillColor])) {
            shape.fillColor = UIColor.whiteColor.CGColor;
        }
    }
    for (CALayer *sub in layer.sublayers) RecolorPurpleLayers(sub, depth - 1);
}

static void ApplyWhiteProgressBar(UISlider *slider) {
    if (!slider) return;

    UIColor *white = UIColor.whiteColor;
    UIColor *dim = [UIColor colorWithWhite:1.0 alpha:0.28];
    BOOL changed = NO;

    if (![slider.tintColor isEqual:white]) {
        slider.tintColor = white;
        changed = YES;
    }
    if (![slider.minimumTrackTintColor isEqual:white]) {
        slider.minimumTrackTintColor = white;
        changed = YES;
    }
    if (![slider.maximumTrackTintColor isEqual:dim]) {
        slider.maximumTrackTintColor = dim;
        changed = YES;
    }
    if (![slider.thumbTintColor isEqual:white]) {
        slider.thumbTintColor = white;
        changed = YES;
    }

    // Sliders painted with track images ignore the tint properties: recolour
    // the existing image (keeps its shape and thickness) instead of replacing it.
    UIImage *minimumImage = [slider minimumTrackImageForState:UIControlStateNormal];
    if (minimumImage) {
        UIImage *cached = objc_getAssociatedObject(slider, &kWhiteTrackImageKey);
        if (cached != minimumImage) {
            UIImage *recoloured = [minimumImage imageWithTintColor:white
                                                     renderingMode:UIImageRenderingModeAlwaysOriginal];
            if (recoloured) {
                [slider setMinimumTrackImage:recoloured forState:UIControlStateNormal];
                objc_setAssociatedObject(slider, &kWhiteTrackImageKey, recoloured,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                changed = YES;
            }
        }
    }

    // Custom drawn sliders (Stremio's ProgressSlider) colour layers directly.
    static NSInteger recolourTick = 0;
    recolourTick++;
    if (changed || recolourTick % 60 == 0) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        RecolorPurpleLayers(slider.layer, 8);
        [CATransaction commit];
    }
}

#pragma mark - Live scrubbing helpers (player lookup + coalesced seeks)

// --- Live scrub tuning ------------------------------------------------------
// Minimum time between two live seeks while dragging (seconds). 0.15 = ~7/s.
static const CGFloat kLiveSeekPumpInterval = 0.15;
// Pause the player while dragging so no audio leaks between seeks.
static const BOOL kLiveScrubPauseDuringScrub = YES;
// Master switch for the live-frame behaviour.
static const BOOL kLiveScrubEnabled = YES;
// ---------------------------------------------------------------------------

static BOOL OPIsNumberOfType(const char *type) {
    if (!type) return NO;
    switch (type[0]) {
        case 'd': case 'f': case 'B': case 'c': case 'b':
        case 'q': case 'Q': case 'i': case 'I':
            return YES;
        default:
            return NO;
    }
}

// Finds a selector on `object` (walking its superclasses) whose name matches one
// of `needles` and whose signature has exactly `argumentCount` arguments.
static SEL OPFindSelector(id object, NSArray<NSString *> *needles, BOOL exact,
                          NSInteger argumentCount, char *outArgumentType) {
    if (!object) return NULL;
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        NSString *className = NSStringFromClass(cls);
        if ([visited containsObject:className]) break;
        [visited addObject:className];
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            SEL selector = method_getName(methods[i]);
            NSString *name = NSStringFromSelector(selector);
            BOOL matches = NO;
            for (NSString *needle in needles) {
                if (exact ? [name isEqualToString:needle]
                          : [name rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    matches = YES;
                    break;
                }
            }
            if (!matches) continue;
            NSMethodSignature *signature = [object methodSignatureForSelector:selector];
            if (!signature) continue;
            if ((NSInteger)signature.numberOfArguments != argumentCount + 2) continue;
            if (argumentCount == 1) {
                const char *type = [signature getArgumentTypeAtIndex:2];
                if (!OPIsNumberOfType(type)) continue;
                if (outArgumentType) *outArgumentType = type[0];
            } else if (outArgumentType) {
                *outArgumentType = 0;
            }
            free(methods);
            return selector;
        }
        free(methods);
    }
    return NULL;
}

static NSNumber *OPNumberValueForKey(id object, NSString *key) {
    if (!object) return nil;
    @try {
        id value = [object valueForKey:key];
        if ([value isKindOfClass:[NSNumber class]]) return (NSNumber *)value;
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

// Walks the responder chain and the ivars of the player view controller to find
// an object that looks like the playback backend (AVPlayer, KSPlayer wrapper,
// Stremio player manager, ...). Returns nil when nothing is reachable.
static id OPFindPlayerObject(UIView *view) {
    UIResponder *responder = view;
    while (responder && ![responder isKindOfClass:[UIViewController class]]) {
        responder = responder.nextResponder;
    }
    NSMutableArray *queue = [NSMutableArray array];
    if (responder) [queue addObject:responder];
    NSMutableSet *seen = [NSMutableSet set];

    for (NSInteger guard = 0; guard < 80 && queue.count > 0; guard++) {
        id object = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (!object || [seen containsObject:object]) continue;
        [seen addObject:object];

        if ([object isKindOfClass:[UIViewController class]]) {
            for (UIViewController *child in ((UIViewController *)object).childViewControllers) {
                [queue addObject:child];
            }
        }

        BOOL looksLikePlayer = OPFindSelector(object, @[@"seek"], NO, 1, NULL) != NULL &&
                               OPFindSelector(object, @[@"pause"], YES, 0, NULL) != NULL;
        if (!looksLikePlayer && [object isKindOfClass:[NSObject class]]) {
            NSString *className = NSStringFromClass([object class]);
            looksLikePlayer = ([className containsString:@"Player"] || [className containsString:@"AVPlayer"]) &&
                              OPFindSelector(object, @[@"seek"], NO, 1, NULL) != NULL;
        }
        if (looksLikePlayer) return object;

        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList([object class], &count);
        for (unsigned int i = 0; i < count; i++) {
            Ivar ivar = ivars[i];
            const char *type = ivar_getTypeEncoding(ivar);
            if (!type || type[0] != '@') continue;
            NSString *name = [NSString stringWithUTF8String:ivar_getName(ivar)].lowercaseString;
            if ([name containsString:@"player"] || [name containsString:@"manager"] ||
                [name containsString:@"layer"]) {
                id value = object_getIvar(object, ivar);
                if (value) [queue addObject:value];
            }
        }
        free(ivars);
    }
    return nil;
}

@interface OPScrubber : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *controls;
@property (nonatomic, weak) UIPanGestureRecognizer *pan;
@property (nonatomic, assign) BOOL scrubbing;
@property (nonatomic, assign) double startTime;
@property (nonatomic, assign) double duration;
@property (nonatomic, assign) double playbackTime;
@property (nonatomic, strong) UIView *pill;
@property (nonatomic, strong) UILabel *targetLabel;
@property (nonatomic, strong) UILabel *arrowLabel;
@property (nonatomic, strong) UIView *line;
@property (nonatomic, strong) UIView *lineFill;
@property (nonatomic, strong) UILabel *positionLabel;
@property (nonatomic, strong) UILabel *durationLabel;
@property (nonatomic, assign) CGFloat pillWidth;
@property (nonatomic, assign) double durationForWidth;
@property (nonatomic, assign) BOOL liveSession;
@property (nonatomic, assign) BOOL scrubWasPlaying;
@property (nonatomic, assign) BOOL pausedByUs;
@property (nonatomic, assign) BOOL mutedByUs;
@property (nonatomic, assign) BOOL muteStateSaved;
@property (nonatomic, assign) BOOL savedMuted;
@property (nonatomic, assign) float savedVolume;
@property (nonatomic, assign) NSTimeInterval lastPumpTime;
@property (nonatomic, strong) id seekTarget;
@property (nonatomic, assign) SEL seekSelector;
@property (nonatomic, assign) SEL pauseSelector;
@property (nonatomic, assign) SEL playSelector;
@property (nonatomic, assign) SEL muteSelector;
@property (nonatomic, assign) SEL volumeSelector;
@property (nonatomic, assign) char seekArgType;
- (void)cancelLiveSession;
@end

@implementation OPScrubber

- (void)call:(SEL)selector argument:(id)argument {
    UIView *controls = self.controls;
    if (!controls || ![controls respondsToSelector:selector]) return;
    ((VoidObjFn)objc_msgSend)(controls, selector, argument);
}

- (UISlider *)slider {
    return CachedSlider(self.controls);
}

- (double)livePlaybackTimeWithFallback:(double)fallback {
    NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
    NSNumber *elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime];
    if (elapsed) {
        double value = elapsed.doubleValue;
        if (isfinite(value) && value >= 0.0 && (self.duration <= 0.0 || value <= self.duration + 1.0)) {
            return value;
        }
    }
    return fallback;
}

#pragma mark Live scrubbing

- (void)resolveLiveSeeker {
    if (self.seekTarget && self.seekSelector) return;
    id target = OPFindPlayerObject(self.controls);
    if (!target) return;

    char argumentType = 0;
    SEL seek = OPFindSelector(target, @[@"seek"], NO, 1, &argumentType);
    if (!seek) return;

    self.seekTarget = target;
    self.seekSelector = seek;
    self.seekArgType = argumentType;
    self.pauseSelector = OPFindSelector(target, @[@"pause"], YES, 0, NULL);
    self.playSelector = OPFindSelector(target, @[@"play"], YES, 0, NULL);
    self.muteSelector = OPFindSelector(target, @[@"setMuted", @"setMute", @"setAudioMuted"], NO, 1, NULL);
    if (!self.muteSelector) {
        self.volumeSelector = OPFindSelector(target, @[@"setVolume"], YES, 1, NULL);
    }
    NSLog(@"[OutplayerTweak] live seek target %@ seek=%@ pause=%@ play=%@ mute=%@",
          NSStringFromClass([target class]),
          NSStringFromSelector(seek),
          self.pauseSelector ? NSStringFromSelector(self.pauseSelector) : @"-",
          self.playSelector ? NSStringFromSelector(self.playSelector) : @"-",
          self.muteSelector ? NSStringFromSelector(self.muteSelector) : (self.volumeSelector ? @"volume" : @"-"));
}

- (void)applyMute:(BOOL)muted {
    id target = self.seekTarget;
    if (!target) return;

    if (self.muteSelector) {
        if (muted) {
            if (!self.muteStateSaved) {
                NSNumber *current = OPNumberValueForKey(target, @"muted");
                self.savedMuted = current ? current.boolValue : NO;
                self.muteStateSaved = YES;
            }
            ((void (*)(id, SEL, BOOL))objc_msgSend)(target, self.muteSelector, YES);
            self.mutedByUs = YES;
        } else if (self.mutedByUs) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(target, self.muteSelector, self.savedMuted);
            self.mutedByUs = NO;
        }
        return;
    }

    if (self.volumeSelector) {
        if (muted) {
            if (!self.muteStateSaved) {
                NSNumber *current = OPNumberValueForKey(target, @"volume");
                self.savedVolume = current ? current.floatValue : 1.0f;
                self.muteStateSaved = YES;
            }
            ((void (*)(id, SEL, float))objc_msgSend)(target, self.volumeSelector, 0.0f);
            self.mutedByUs = YES;
        } else if (self.mutedByUs) {
            ((void (*)(id, SEL, float))objc_msgSend)(target, self.volumeSelector, self.savedVolume);
            self.mutedByUs = NO;
        }
    }
}

- (void)pauseForScrub {
    if (self.pausedByUs) return;
    id target = self.seekTarget;
    if (target && self.pauseSelector) {
        ((void (*)(id, SEL))objc_msgSend)(target, self.pauseSelector);
        self.pausedByUs = YES;
        return;
    }
    UIView *controls = self.controls;
    if ([controls respondsToSelector:@selector(onPlayButtonTap:)]) {
        id sender = objc_getAssociatedObject(controls, &kPlayButtonKey);
        CallVoidObj(controls, @selector(onPlayButtonTap:), sender);
        self.pausedByUs = YES;
    }
}

- (void)resumeAfterScrub {
    if (!self.pausedByUs) return;
    id target = self.seekTarget;
    if (target && self.playSelector) {
        ((void (*)(id, SEL))objc_msgSend)(target, self.playSelector);
    } else {
        UIView *controls = self.controls;
        if ([controls respondsToSelector:@selector(onPlayButtonTap:)]) {
            id sender = objc_getAssociatedObject(controls, &kPlayButtonKey);
            CallVoidObj(controls, @selector(onPlayButtonTap:), sender);
        }
    }
    self.pausedByUs = NO;
}

- (void)seekPlayerTo:(double)seconds {
    id target = self.seekTarget;
    if (target && self.seekSelector) {
        char type = self.seekArgType;
        if (type == 'f') {
            ((void (*)(id, SEL, float))objc_msgSend)(target, self.seekSelector, (float)seconds);
        } else if (type == 'q' || type == 'Q' || type == 'i' || type == 'I') {
            ((void (*)(id, SEL, long long))objc_msgSend)(target, self.seekSelector,
                                                         (long long)llround(seconds));
        } else {
            ((void (*)(id, SEL, double))objc_msgSend)(target, self.seekSelector, seconds);
        }
        return;
    }

    // Fallback: Stremio's own slider handlers perform the real seek when the
    // "touch up" event arrives, so fire one and re-enter the drag state.
    UIView *controls = self.controls;
    UISlider *slider = [self slider];
    if (!controls || !slider) return;
    [self call:@selector(onSliderTouchUpInside:) argument:slider];
    [self call:@selector(onSliderTouchDown:) argument:slider];
}

- (void)beginLiveSession {
    if (!kLiveScrubEnabled || self.liveSession) return;
    self.liveSession = YES;
    self.scrubWasPlaying = CurrentlyPlaying();
    self.pausedByUs = NO;
    self.mutedByUs = NO;
    self.muteStateSaved = NO;
    self.lastPumpTime = 0.0;

    [self resolveLiveSeeker];
    if (kLiveScrubPauseDuringScrub && self.scrubWasPlaying) {
        [self pauseForScrub];
    }
    [self applyMute:YES];
}

- (void)finishLiveSession {
    if (!self.liveSession) return;
    self.liveSession = NO;
    [self applyMute:NO];
    [self resumeAfterScrub];
    self.seekTarget = nil;
    self.seekSelector = NULL;
    self.pauseSelector = NULL;
    self.playSelector = NULL;
    self.muteSelector = NULL;
    self.volumeSelector = NULL;
    self.seekArgType = 0;
}

- (void)cancelLiveSession {
    if (!self.liveSession) return;
    self.scrubbing = NO;
    [self finishLiveSession];
}

- (void)liveSeekTo:(double)seconds force:(BOOL)force {
    if (!kLiveScrubEnabled || !self.liveSession) return;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (!force && now - self.lastPumpTime < kLiveSeekPumpInterval) return;
    self.lastPumpTime = now;

    [self resolveLiveSeeker];
    [self seekPlayerTo:seconds];

    // The fallback path goes through Stremio's handlers, which may resume
    // playback: keep the scrub silent.
    if (self.scrubWasPlaying && !self.seekTarget && CurrentlyPlaying()) {
        self.pausedByUs = NO;
        [self pauseForScrub];
    }
}

#pragma mark Pill

// Pill geometry (matches the Outplayer scrub indicator).
static const CGFloat kPillPadding = 12.0;
static const CGFloat kPillCornerRadius = 16.0;
static const CGFloat kPillRow1Height = 34.0;
static const CGFloat kPillLineHeight = 2.0;
static const CGFloat kPillRow3Height = 16.0;
static const CGFloat kPillRow1Y = 12.0;
static const CGFloat kPillLineY = 54.0;
static const CGFloat kPillRow3Y = 64.0;
static const CGFloat kPillHeight = 92.0;
static const CGFloat kPillMinContentWidth = 96.0;
static const CGFloat kPillEdgeMargin = 16.0;

- (UIView *)ensurePill {
    UIView *controls = self.controls;
    if (!controls) return nil;
    if (self.pill && self.pill.superview == controls) return self.pill;

    UIView *pill = [[UIView alloc] initWithFrame:CGRectZero];
    pill.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.68];
    pill.layer.cornerRadius = kPillCornerRadius;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.userInteractionEnabled = NO;
    pill.alpha = 0.0;
    pill.clipsToBounds = YES;

    UIFont *targetFont = InterTabularFont(28.0, UIFontWeightBold);
    UIFont *arrowFont = InterFont(22.0, UIFontWeightSemibold);
    UIFont *smallFont = InterTabularFont(12.0, UIFontWeightMedium);

    UILabel *target = [[UILabel alloc] initWithFrame:CGRectZero];
    target.font = targetFont;
    target.textColor = UIColor.whiteColor;
    target.textAlignment = NSTextAlignmentLeft;
    target.numberOfLines = 1;
    target.lineBreakMode = NSLineBreakByClipping;
    target.adjustsFontSizeToFitWidth = YES;
    target.minimumScaleFactor = 0.6;

    UILabel *arrow = [[UILabel alloc] initWithFrame:CGRectZero];
    arrow.font = arrowFont;
    arrow.textColor = UIColor.whiteColor;
    arrow.textAlignment = NSTextAlignmentRight;
    arrow.numberOfLines = 1;
    arrow.text = @"→";

    UIView *line = [[UIView alloc] initWithFrame:CGRectZero];
    line.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.24];
    line.layer.cornerRadius = kPillLineHeight / 2.0;
    line.clipsToBounds = YES;
    line.userInteractionEnabled = NO;

    UIView *fill = [[UIView alloc] initWithFrame:CGRectZero];
    fill.backgroundColor = UIColor.whiteColor;
    fill.userInteractionEnabled = NO;
    [line addSubview:fill];

    UILabel *position = [[UILabel alloc] initWithFrame:CGRectZero];
    position.font = smallFont;
    position.textColor = [UIColor colorWithWhite:1.0 alpha:0.88];
    position.textAlignment = NSTextAlignmentLeft;
    position.numberOfLines = 1;
    position.lineBreakMode = NSLineBreakByClipping;
    position.adjustsFontSizeToFitWidth = YES;
    position.minimumScaleFactor = 0.6;

    UILabel *total = [[UILabel alloc] initWithFrame:CGRectZero];
    total.font = smallFont;
    total.textColor = [UIColor colorWithWhite:1.0 alpha:0.48];
    total.textAlignment = NSTextAlignmentRight;
    total.numberOfLines = 1;
    total.lineBreakMode = NSLineBreakByClipping;
    total.adjustsFontSizeToFitWidth = YES;
    total.minimumScaleFactor = 0.6;

    [pill addSubview:target];
    [pill addSubview:arrow];
    [pill addSubview:line];
    [pill addSubview:position];
    [pill addSubview:total];
    [controls addSubview:pill];

    self.pill = pill;
    self.targetLabel = target;
    self.arrowLabel = arrow;
    self.line = line;
    self.lineFill = fill;
    self.positionLabel = position;
    self.durationLabel = total;
    self.pillWidth = 0.0;
    self.durationForWidth = -1.0;
    return pill;
}

// Width is derived from the total duration so it never changes while dragging.
- (CGFloat)contentWidthForDuration:(double)duration {
    NSString *widest = FormatClock(duration);
    CGFloat targetWidth = MeasuredWidth(widest, self.targetLabel.font);
    CGFloat arrowWidth = MAX(24.0, MeasuredWidth(@"→", self.arrowLabel.font));
    CGFloat smallWidth = MeasuredWidth(widest, self.positionLabel.font);

    CGFloat row1 = targetWidth + 8.0 + arrowWidth;
    CGFloat row3 = smallWidth * 2.0 + 16.0;
    return MAX(kPillMinContentWidth, MAX(row1, row3));
}

- (void)preparePillForDuration:(double)duration {
    [self ensurePill];
    if (self.pillWidth <= 0.0 || fabs(self.durationForWidth - duration) > 0.5) {
        self.durationForWidth = duration;
        CGFloat content = [self contentWidthForDuration:duration];
        self.pillWidth = content + kPillPadding * 2.0;
    }
    [self layoutPill];
}

- (void)layoutPill {
    UIView *controls = self.controls;
    UIView *pill = self.pill;
    if (!controls || !pill) return;
    if (self.pillWidth <= 0.0) return;

    CGFloat safeTop = controls.safeAreaInsets.top;
    CGFloat safeLeft = controls.safeAreaInsets.left;
    if (safeTop <= 0.0 && controls.window) safeTop = controls.window.safeAreaInsets.top;
    if (safeLeft <= 0.0 && controls.window) safeLeft = controls.window.safeAreaInsets.left;
    if (safeTop < 0.0) safeTop = 0.0;
    if (safeLeft < 0.0) safeLeft = 0.0;

    CGFloat content = self.pillWidth - kPillPadding * 2.0;
    CGFloat arrowWidth = MAX(24.0, MeasuredWidth(@"→", self.arrowLabel.font));
    CGFloat targetWidth = MAX(0.0, content - arrowWidth - 8.0);
    CGFloat smallWidth = floor(content * 0.5);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [UIView performWithoutAnimation:^{
        pill.frame = CGRectMake(safeLeft + kPillEdgeMargin, safeTop + kPillEdgeMargin,
                                self.pillWidth, kPillHeight);
        self.targetLabel.frame = CGRectMake(kPillPadding, kPillRow1Y, targetWidth, kPillRow1Height);
        self.arrowLabel.frame = CGRectMake(kPillPadding + content - arrowWidth, kPillRow1Y, arrowWidth,
                                           kPillRow1Height);
        self.line.frame = CGRectMake(kPillPadding, kPillLineY, content, kPillLineHeight);
        self.lineFill.frame = CGRectMake(0.0, 0.0, 0.0, kPillLineHeight);
        self.positionLabel.frame = CGRectMake(kPillPadding, kPillRow3Y, smallWidth, kPillRow3Height);
        self.durationLabel.frame = CGRectMake(kPillPadding + content - smallWidth, kPillRow3Y, smallWidth,
                                              kPillRow3Height);
        [pill layoutIfNeeded];
    }];
    [CATransaction commit];
}

- (void)showPillForDuration:(double)duration {
    [self preparePillForDuration:duration];
    [self.controls bringSubviewToFront:self.pill];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.pill.alpha = 1.0;
    [CATransaction commit];
}

- (void)hidePillSoon {
    __weak OPScrubber *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        OPScrubber *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.scrubbing) return;
        [UIView animateWithDuration:0.25 animations:^{
            strongSelf.pill.alpha = 0.0;
        }];
    });
}

#pragma mark Scrubbing

- (void)renderTarget:(double)target delta:(double)delta {
    UIView *line = self.line;
    if (!line) return;

    CGFloat progress = self.duration > 0.0 ? (CGFloat)(target / self.duration) : 0.0;
    if (!isfinite(progress)) progress = 0.0;
    progress = MAX(0.0, MIN(1.0, progress));
    CGFloat fillWidth = floor(line.bounds.size.width * progress);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [UIView performWithoutAnimation:^{
        self.targetLabel.text = FormatClock(target);
        self.arrowLabel.text = delta < 0.0 ? @"←" : @"→";
        self.positionLabel.text = FormatClock(self.playbackTime);
        self.durationLabel.text = FormatClock(self.duration);
        self.lineFill.frame = CGRectMake(0.0, 0.0, fillWidth, kPillLineHeight);
        [self.lineFill.superview layoutIfNeeded];
    }];
    [CATransaction commit];
}

- (void)applyDrag:(CGFloat)dx {
    UIView *controls = self.controls;
    UISlider *slider = [self slider];
    if (!controls || !slider || self.duration <= 0) return;

    CGFloat width = controls.bounds.size.width;
    if (!(width > 1.0)) width = 1.0;

    double delta = ((double)dx / (double)width) * self.duration * kScrubSpanFraction;
    double target = self.startTime + delta;
    if (target < 0) target = 0;
    if (target > self.duration) target = self.duration;

    SliderSetProgress(slider, target / self.duration);
    [self call:@selector(onSliderValChanged:) argument:slider];
    [self renderTarget:target delta:delta];
    [self liveSeekTo:target force:NO];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *controls = self.controls;
    UISlider *slider = [self slider];
    if (!controls || !slider) return;

    CGPoint translation = [pan translationInView:pan.view];

    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            double duration = CurrentDuration(controls);
            if (duration <= 0) return;
            self.duration = duration;
            self.startTime = SliderProgress(slider) * duration;
            self.playbackTime = [self livePlaybackTimeWithFallback:self.startTime];
            self.scrubbing = YES;
            [self showPillForDuration:duration];
            [self beginLiveSession];
            [self call:@selector(onSliderTouchDown:) argument:slider];
            [self applyDrag:translation.x];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!self.scrubbing) return;
            [self applyDrag:translation.x];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            if (!self.scrubbing) return;
            [self applyDrag:translation.x];
            self.scrubbing = NO;
            UISlider *current = [self slider] ?: slider;
            double finalTime = SliderProgress(current) * self.duration;
            [self liveSeekTo:finalTime force:YES];
            [self call:@selector(onSliderTouchUpInside:) argument:current];
            [self finishLiveSession];
            [self hidePillSoon];
            break;
        }
        default:
            break;
    }
}

#pragma mark UIGestureRecognizerDelegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (![gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) return YES;
    CGPoint velocity = [(UIPanGestureRecognizer *)gestureRecognizer velocityInView:gestureRecognizer.view];
    if (fabs(velocity.y) > fabs(velocity.x) * 0.77) return NO;
    return [self slider] != nil && CurrentDuration(self.controls) > 0;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    UIView *controls = self.controls;
    UIView *view = touch.view;
    if (!controls || !view) return YES;
    if ([view isKindOfClass:[UIControl class]]) return NO;

    UIView *transportPill = objc_getAssociatedObject(controls, &kTransportPillKey);
    UIView *progressPill = objc_getAssociatedObject(controls, &kProgressPillKey);
    UIView *rightPill = objc_getAssociatedObject(controls, &kRightPillKey);

    UIView *cursor = view;
    while (cursor) {
        if (cursor == transportPill || cursor == progressPill || cursor == rightPill) return NO;
        cursor = cursor.superview;
    }
    return YES;
}

@end

static void AbortLiveScrubbing(UIView *controls) {
    if (!controls) return;
    OPScrubber *scrubber = objc_getAssociatedObject(controls, &kScrubberKey);
    if (!scrubber) return;
    [scrubber cancelLiveSession];
}

static void SetupScrub(UIView *controls) {
    if (!controls) return;

    if (!objc_getAssociatedObject(controls, &kScrubberKey)) {
        UIView *host = controls.superview ?: controls;
        OPScrubber *scrubber = [[OPScrubber alloc] init];
        scrubber.controls = controls;

        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:scrubber action:@selector(handlePan:)];
        pan.delegate = scrubber;
        pan.cancelsTouchesInView = NO;
        pan.maximumNumberOfTouches = 1;
        [host addGestureRecognizer:pan];
        scrubber.pan = pan;

        objc_setAssociatedObject(controls, &kScrubberKey, scrubber, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        __weak UIView *weakControls = controls;
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) {
            AbortLiveScrubbing(weakControls);
        }];
        NSLog(@"[OutplayerTweak] scrub gesture attached to %@", NSStringFromClass([host class]));
    }

    // Stremio re-applies its accent tint whenever the controls rebuild, so the
    // white bar is re-asserted on every layout pass (cheap when already white).
    ApplyWhiteProgressBar(CachedSlider(controls));
}

#pragma mark - Tap to play/pause

static BOOL MediaIsReady(UIView *controls) {
    UISlider *slider = objc_getAssociatedObject(controls, &kSliderKey);
    if (!slider) slider = FindProgressSlider(controls);
    return slider != nil && CurrentDuration(controls) > 0;
}

static void TogglePlayback(UIView *controls) {
    if (!controls) return;

    UIButton *playButton = objc_getAssociatedObject(controls, &kPlayButtonKey);
    if ([controls respondsToSelector:@selector(onPlayButtonTap:)]) {
        CallVoidObj(controls, @selector(onPlayButtonTap:), playButton ? (id)playButton : (id)controls);
    } else if (playButton) {
        [playButton sendActionsForControlEvents:UIControlEventTouchUpInside];
    } else {
        // Last resort: find a sizeable button in Stremio's own 2.1.0 layout.
        UIButton *found = nil;
        for (UIView *view in controls.subviews) {
            if ([view isKindOfClass:[UIButton class]] && view.bounds.size.width >= 44.0 &&
                view.bounds.size.height >= 44.0) {
                found = (UIButton *)view;
                break;
            }
        }
        if (!found) return;
        [found sendActionsForControlEvents:UIControlEventTouchUpInside];
    }

    gOptimisticPlaying = !gOptimisticPlaying;
    UpdatePlayIcon(controls);
    UpdatePlayIconSoon(controls);
}

@interface OPTapper : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *controls;
@property (nonatomic, weak) UIView *host;
@end

@implementation OPTapper

- (void)handleTap:(UITapGestureRecognizer *)tap {
    UIView *controls = self.controls;
    if (!controls || !MediaIsReady(controls)) return;
    TogglePlayback(controls);
}

- (BOOL)isExcluded:(UIView *)view {
    UIView *controls = self.controls;
    if (!controls || !view) return NO;
    if ([view isKindOfClass:[UIControl class]]) return YES;

    UIView *transportPill = objc_getAssociatedObject(controls, &kTransportPillKey);
    UIView *progressPill = objc_getAssociatedObject(controls, &kProgressPillKey);
    UIView *rightPill = objc_getAssociatedObject(controls, &kRightPillKey);

    UIView *cursor = view;
    while (cursor) {
        if (cursor == transportPill || cursor == progressPill || cursor == rightPill) return YES;
        cursor = cursor.superview;
    }
    return NO;
}

- (BOOL)isCenterPoint:(CGPoint)point inView:(UIView *)view {
    if (!view) return NO;
    CGSize size = view.bounds.size;
    if (size.width < 1.0 || size.height < 1.0) return NO;
    CGFloat dx = fabs(point.x - size.width / 2.0) / (size.width / 2.0);
    CGFloat dy = fabs(point.y - size.height / 2.0) / (size.height / 2.0);
    return dx <= 0.62 && dy <= 0.72;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if ([self isExcluded:touch.view]) return NO;

    if ([gestureRecognizer isKindOfClass:[UITapGestureRecognizer class]]) {
        UITapGestureRecognizer *tap = (UITapGestureRecognizer *)gestureRecognizer;
        if (tap.numberOfTouchesRequired == 1) {
            // Centre tap only: edges stay free for Stremio's own hit areas.
            CGPoint point = [touch locationInView:gestureRecognizer.view];
            if (![self isCenterPoint:point inView:gestureRecognizer.view]) return NO;
        }
    }
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    UIView *controls = self.controls;
    if (!controls) return NO;
    return MediaIsReady(controls);
}

@end

static void SetupTaps(UIView *controls) {
    if (objc_getAssociatedObject(controls, &kTapperKey)) return;

    UIView *host = controls.superview ?: controls;
    OPTapper *tapper = [[OPTapper alloc] init];
    tapper.controls = controls;
    tapper.host = host;

    UITapGestureRecognizer *centerTap = [[UITapGestureRecognizer alloc] initWithTarget:tapper action:@selector(handleTap:)];
    centerTap.numberOfTapsRequired = 1;
    centerTap.numberOfTouchesRequired = 1;
    centerTap.delegate = tapper;
    centerTap.cancelsTouchesInView = NO;
    [host addGestureRecognizer:centerTap];

    UITapGestureRecognizer *twoFingerTap = [[UITapGestureRecognizer alloc] initWithTarget:tapper action:@selector(handleTap:)];
    twoFingerTap.numberOfTapsRequired = 1;
    twoFingerTap.numberOfTouchesRequired = 2;
    twoFingerTap.delegate = tapper;
    twoFingerTap.cancelsTouchesInView = NO;
    [host addGestureRecognizer:twoFingerTap];

    objc_setAssociatedObject(controls, &kTapperKey, tapper, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[OutplayerTweak] tap gestures attached to %@", NSStringFromClass([host class]));
}

#pragma mark - Subtitles (KSPlayer VideoSubtitleView)

// Stremio renders on-device subtitles with KSPlayer: the text track is decoded by
// FFmpeg and drawn by KSPlayer's SwiftUI VideoSubtitleView, which lives in a
// UIHostingController that Stremio stores as `subtitleVC`. The player used here is
// KSPlayerLayerManager (VLCPlayerManager/MobileVLCKit is only used when the
// `useVLCKit` setting is on, and libmpv is not linked at all). KSOptions' static
// text style properties drive that view, so the tweak adjusts both the placement
// of the hosting view and the static text colour.

// --- Tuning constants -------------------------------------------------------
// Distance in points between the subtitle block and the top of the bottom
// control row. Increase to push subtitles further up.
static const CGFloat kSubtitleGapAboveControls = 26.0;
// KSPlayer's own bottom padding above the view's bottom edge (used to convert
// the current position into a lift distance).
static const CGFloat kSubtitleAssumedBaseInset = 16.0;
// Clamp for the computed lift, as a fraction of the subtitle view height.
static const CGFloat kSubtitleMinLiftFraction = 0.04;
static const CGFloat kSubtitleMaxLiftFraction = 0.22;
// Fallback target when the bottom control row cannot be measured: share of the
// screen height kept free below the subtitles.
static const CGFloat kSubtitleFallbackBottomFraction = 0.15;
// Subtitle grey level (0-1) forced through KSOptions.textColor.
static const CGFloat kSubtitleTextWhite = 0.94;
// Set to NO to leave KSPlayer's own text colour untouched.
static const BOOL kForceSubtitleTextColor = YES;
// Set to NO to keep Stremio's bottom dimming gradient above the video.
static const BOOL kHideControlsScrim = YES;
// ---------------------------------------------------------------------------

static __weak UIView *gSubtitleHost = nil;
static BOOL gSubtitleStyleApplied = NO;
static CFAbsoluteTime gLastSubtitleSearch = 0.0;

static BOOL AddressIsExecutable(const void *address) {
    if (!address) return NO;
    uintptr_t target = (uintptr_t)address;
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        if (!header) continue;
        BOOL is64 = (header->magic == MH_MAGIC_64);
        if (!is64 && header->magic != MH_MAGIC) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        uint32_t ncmds = is64 ? ((const struct mach_header_64 *)header)->ncmds : header->ncmds;
        const uint8_t *cursor = (const uint8_t *)header +
                                (is64 ? sizeof(struct mach_header_64) : sizeof(struct mach_header));
        for (uint32_t c = 0; c < ncmds; c++) {
            const struct load_command *command = (const struct load_command *)cursor;
            if (command->cmdsize == 0) break;
            if (command->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *segment = (const struct segment_command_64 *)cursor;
                uintptr_t start = (uintptr_t)(segment->vmaddr + (uint64_t)slide);
                uintptr_t end = start + (uintptr_t)segment->vmsize;
                if (target >= start && target < end) {
                    return (segment->initprot & VM_PROT_EXECUTE) != 0;
                }
            } else if (command->cmd == LC_SEGMENT) {
                const struct segment_command *segment = (const struct segment_command *)cursor;
                uintptr_t start = (uintptr_t)(segment->vmaddr + (uint32_t)slide);
                uintptr_t end = start + (uintptr_t)segment->vmsize;
                if (target >= start && target < end) {
                    return (segment->initprot & VM_PROT_EXECUTE) != 0;
                }
            }
            cursor += command->cmdsize;
        }
    }
    return NO;
}

// KSOptions.textColor / textStrokeColor are Swift static properties. The binary
// exports their unsafe addressors, which return a pointer to the storage slot.
static void ForceSubtitleTextStyle(void) {
    if (!kForceSubtitleTextColor || gSubtitleStyleApplied) return;

    typedef void *(*AddressorFn)(void);
    AddressorFn colorAddressor =
        (AddressorFn)dlsym(RTLD_DEFAULT, "$s8KSPlayer9KSOptionsC9textColorSo7UIColorCvau");
    if (!colorAddressor || !AddressIsExecutable((const void *)colorAddressor)) return;
    __strong id *colorSlot = (__strong id *)colorAddressor();
    if (!colorSlot) return;
    *colorSlot = [UIColor colorWithWhite:kSubtitleTextWhite alpha:1.0];

    AddressorFn strokeAddressor =
        (AddressorFn)dlsym(RTLD_DEFAULT, "$s8KSPlayer9KSOptionsC15textStrokeColorSo7UIColorCvau");
    if (strokeAddressor && AddressIsExecutable((const void *)strokeAddressor)) {
        __strong id *strokeSlot = (__strong id *)strokeAddressor();
        if (strokeSlot) *strokeSlot = UIColor.blackColor;
    }

    gSubtitleStyleApplied = YES;
    NSLog(@"[OutplayerTweak] forced subtitle text colour");
}

static UIView *FindSubtitleHostInView(UIView *root, NSInteger depth) {
    if (!root || depth < 0) return nil;
    NSString *name = NSStringFromClass([root class]);
    if ([name containsString:@"VideoSubtitleView"] || [name containsString:@"MetalSubtitleView"] ||
        [name containsString:@"KSSSubtitleView"]) {
        return root;
    }
    for (UIView *subview in root.subviews) {
        UIView *found = FindSubtitleHostInView(subview, depth - 1);
        if (found) return found;
    }
    return nil;
}

static UIViewController *FindSubtitleHostController(UIViewController *controller, NSInteger depth) {
    if (!controller || depth < 0) return nil;
    NSString *name = NSStringFromClass([controller class]);
    if ([name containsString:@"VideoSubtitleView"] || [name containsString:@"MetalSubtitleView"]) {
        return controller;
    }
    for (UIViewController *child in controller.childViewControllers) {
        UIViewController *found = FindSubtitleHostController(child, depth - 1);
        if (found) return found;
    }
    return nil;
}

static BOOL LayerTreeHasGradient(CALayer *layer, NSInteger depth) {
    if (!layer || depth < 0) return NO;
    if ([layer isKindOfClass:[CAGradientLayer class]]) return YES;
    for (CALayer *sub in layer.sublayers) {
        if (LayerTreeHasGradient(sub, depth - 1)) return YES;
    }
    return NO;
}

// Stremio draws a dark scrim inside the controls view; it sits above the video
// (and therefore above the subtitles). The tweak draws its own pills, so the
// scrim is only dimming the picture and the subtitles.
static void HideControlsScrim(UIView *controls, NSArray<UIView *> *ours) {
    if (!kHideControlsScrim) return;
    CGFloat width = controls.bounds.size.width;
    CGFloat height = controls.bounds.size.height;
    if (width < 1.0 || height < 1.0) return;

    for (UIView *view in controls.subviews) {
        if ([ours containsObject:view]) continue;
        if ([view isKindOfClass:[UIControl class]]) continue;
        if (view.hidden) continue;
        if (view.bounds.size.width < width * 0.6 || view.bounds.size.height < height * 0.4) continue;
        if (!LayerTreeHasGradient(view.layer, 4)) continue;
        view.hidden = YES;
        view.alpha = 0.0;
    }
}

static void UpdateSubtitlePresentation(UIView *controls) {
    if (!controls) return;

    UIView *host = gSubtitleHost;
    if (!host || !host.window) {
        // Layout fires very often; do not walk the whole window tree every time.
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - gLastSubtitleSearch < 0.5) return;
        gLastSubtitleSearch = now;

        host = FindSubtitleHostInView(controls.window, 40);
        if (!host) {
            UIViewController *hostController =
                FindSubtitleHostController(controls.window.rootViewController, 20);
            host = hostController.view;
        }
        if (host) {
            gSubtitleHost = host;
            gSubtitleStyleApplied = NO;
            NSLog(@"[OutplayerTweak] subtitle host view: %@", NSStringFromClass([host class]));
        }
    }
    if (!host) return;

    ForceSubtitleTextStyle();

    // Keep the subtitle above sibling overlays inside the player view.
    if (host.superview && host.superview.subviews.lastObject != host) {
        [host.superview bringSubviewToFront:host];
    }

    CGFloat height = host.bounds.size.height;
    if (height < 1.0) height = host.superview.bounds.size.height;
    if (height < 1.0) return;

    // Bottom edge of the subtitle block, measured from the top of the host view.
    CGFloat assumedBottom = height - kSubtitleAssumedBaseInset;
    CGFloat targetBottom = height - height * kSubtitleFallbackBottomFraction;

    UIView *transportPill = objc_getAssociatedObject(controls, &kTransportPillKey);
    UIView *progressPill = objc_getAssociatedObject(controls, &kProgressPillKey);
    UIView *rowView = transportPill ?: progressPill;
    if (rowView && rowView.window && host.window) {
        CGRect rowInHost = [rowView convertRect:rowView.bounds toView:host];
        if (CGRectGetWidth(rowInHost) > 1.0 && CGRectGetMinY(rowInHost) > 1.0) {
            targetBottom = CGRectGetMinY(rowInHost) - kSubtitleGapAboveControls;
        }
    } else {
        CGFloat safeBottom = 0.0;
        if (@available(iOS 11.0, *)) safeBottom = host.safeAreaInsets.bottom;
        targetBottom = MIN(targetBottom, height - safeBottom - 43.0 - 13.0 - kSubtitleGapAboveControls);
    }

    CGFloat lift = assumedBottom - targetBottom;
    CGFloat minLift = height * kSubtitleMinLiftFraction;
    CGFloat maxLift = height * kSubtitleMaxLiftFraction;
    if (lift < minLift) lift = minLift;
    if (lift > maxLift) lift = maxLift;
    if (!isfinite(lift) || lift < 0.0) lift = 0.0;

    if (!CGAffineTransformIsIdentity(host.transform)) return;
    CGAffineTransform desired = CGAffineTransformMakeTranslation(0.0, -lift);
    if (!CGAffineTransformEqualToTransform(host.transform, desired)) {
        host.transform = desired;
    }
}

#pragma mark - Hooks

static IMP gOriginalViewDidMoveToWindow = NULL;
static void HookViewDidMoveToWindow(id self, SEL _cmd) {
    if (gOriginalViewDidMoveToWindow) {
        ((void (*)(id, SEL))gOriginalViewDidMoveToWindow)(self, _cmd);
    }
    __weak UIView *weakControls = (UIView *)self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *controls = weakControls;
        if (!controls) return;
        SetupOutplayerUI(controls);
        LayoutOutplayerUI(controls);
        SetupScrub(controls);
        SetupTaps(controls);
        UpdateSubtitlePresentation(controls);
    });
}

static IMP gOriginalLayoutSubviews = NULL;
static void HookLayoutSubviews(id self, SEL _cmd) {
    if (gOriginalLayoutSubviews) {
        ((void (*)(id, SEL))gOriginalLayoutSubviews)(self, _cmd);
    }
    UIView *controls = (UIView *)self;
    if (!controls.window) AbortLiveScrubbing(controls);
    SetupOutplayerUI(controls);
    LayoutOutplayerUI(controls);
    SetupScrub(controls);
    SetupTaps(controls);
    UpdateSubtitlePresentation(controls);
}

static IMP gOriginalShouldReceiveTouch = NULL;
static BOOL HookShouldReceiveTouch(id self, SEL _cmd, UIGestureRecognizer *gesture, UITouch *touch) {
    UIView *touchView = touch.view;
    if ([touchView isKindOfClass:[UIControl class]]) return NO;
    UIView *transportPill = objc_getAssociatedObject(self, &kTransportPillKey);
    UIView *progressPill = objc_getAssociatedObject(self, &kProgressPillKey);
    UIView *rightPill = objc_getAssociatedObject(self, &kRightPillKey);
    UIView *cursor = touchView;
    while (cursor) {
        if (cursor == transportPill || cursor == progressPill || cursor == rightPill) return NO;
        cursor = cursor.superview;
    }
    if (gOriginalShouldReceiveTouch) {
        return ((BOOL (*)(id, SEL, UIGestureRecognizer *, UITouch *))gOriginalShouldReceiveTouch)(self, _cmd, gesture, touch);
    }
    return YES;
}

__attribute__((constructor)) static void TweakInitialize(void) {
    NSLog(@"[OutplayerTweak] loaded");
    RegisterInterFonts();
    Class controlsClass = FindStremioClass(@"VideoControlsView");
    if (!controlsClass) {
        NSLog(@"[OutplayerTweak] VideoControlsView not found");
        return;
    }
    InstallHook(controlsClass, @selector(layoutSubviews), (IMP)HookLayoutSubviews, &gOriginalLayoutSubviews);
    InstallHook(controlsClass, @selector(viewDidMoveToWindow), (IMP)HookViewDidMoveToWindow, &gOriginalViewDidMoveToWindow);
    InstallHook(controlsClass, @selector(gestureRecognizer:shouldReceiveTouch:), (IMP)HookShouldReceiveTouch, &gOriginalShouldReceiveTouch);
    NSLog(@"[OutplayerTweak] hooked %@", NSStringFromClass(controlsClass));
}
