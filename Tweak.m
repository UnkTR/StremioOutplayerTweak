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
    UpdateProgress(controls);
    UpdatePlayIcon(controls);
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
    });
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
