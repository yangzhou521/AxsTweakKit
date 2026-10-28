#import "AxsTweakKitSliderCell.h"
#import <UIKit/UIKit.h>

@interface AxsTweakKitSliderCell ()
@property (nonatomic, strong) UISlider *axsTweakKitSlider;
@property (nonatomic, strong) UILabel *axsTweakKitValueLabel;
@end

@implementation AxsTweakKitSliderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)identifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:UITableViewCellStyleDefault
                reuseIdentifier:identifier
                      specifier:specifier];
    if (self) {
        _axsTweakKitSlider = [[UISlider alloc] initWithFrame:CGRectZero];
        [_axsTweakKitSlider addTarget:self
                               action:@selector(axsTweakKit_sliderMoved:)
                     forControlEvents:UIControlEventValueChanged];
        [_axsTweakKitSlider addTarget:self
                               action:@selector(axsTweakKit_sliderCommitted:)
                     forControlEvents:UIControlEventTouchUpInside |
                                      UIControlEventTouchUpOutside |
                                      UIControlEventTouchCancel];
        [self.contentView addSubview:_axsTweakKitSlider];

        _axsTweakKitValueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _axsTweakKitValueLabel.font =
            [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
        _axsTweakKitValueLabel.textColor = [UIColor secondaryLabelColor];
        _axsTweakKitValueLabel.textAlignment = NSTextAlignmentRight;
        _axsTweakKitValueLabel.adjustsFontSizeToFitWidth = YES;
        _axsTweakKitValueLabel.minimumScaleFactor = 0.6;
        [self.contentView addSubview:_axsTweakKitValueLabel];

        self.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        [self axsTweakKit_reloadState];
    }
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self axsTweakKit_reloadState];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    // A reused cell must not hold a stale controller or specifier.
    self.axsTweakKitHandler = nil;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    CGFloat height = CGRectGetHeight(self.contentView.bounds);
    CGFloat available = MAX(0.0, width - 32.0);
    CGFloat valueWidth = MIN(52.0, available * 0.25);
    CGFloat titleWidth = MIN(110.0, available * 0.32);
    CGFloat sliderX = 16.0 + titleWidth + 8.0;
    CGFloat valueX = MAX(sliderX, width - 16.0 - valueWidth);

    self.textLabel.frame = CGRectMake(16.0, 0.0, titleWidth, height);
    self.axsTweakKitSlider.frame =
        CGRectMake(sliderX, MAX(0.0, (height - 31.0) / 2.0),
                   MAX(0.0, valueX - 8.0 - sliderX), 31.0);
    self.axsTweakKitValueLabel.frame = CGRectMake(valueX, 0.0, valueWidth, height);
}

#pragma mark - State

- (void)axsTweakKit_reloadState {
    // The framework may refresh a cell off the main thread; controls are
    // only ever touched on it.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self axsTweakKit_reloadState];
        });
        return;
    }

    self.textLabel.text = self.specifier.name ?: @"";
    self.axsTweakKitSlider.accessibilityLabel = self.textLabel.text;

    double minimum = [[self.specifier propertyForKey:@"min"] doubleValue];
    double maximum = [[self.specifier propertyForKey:@"max"] doubleValue];
    if (!isfinite(minimum)) minimum = 0.0;
    if (!isfinite(maximum) || maximum <= minimum) maximum = minimum + 1.0;
    self.axsTweakKitSlider.minimumValue = minimum;
    self.axsTweakKitSlider.maximumValue = maximum;

    id initial = [self.specifier propertyForKey:@"default"];
    double value = self.axsTweakKitHandler
                       ? [self.axsTweakKitHandler axsTweakKit_sliderValueForSpecifier:self.specifier]
                       : [initial doubleValue];
    if (!isfinite(value)) value = minimum;
    self.axsTweakKitSlider.value = fmax(minimum, fmin(maximum, value));

    [self axsTweakKit_updateValueLabel];
}

- (void)axsTweakKit_updateValueLabel {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self axsTweakKit_updateValueLabel];
        });
        return;
    }
    // One decimal by default; change the format here and the range in
    // Root.plist together when the value is a percentage, not one of them.
    NSString *value = [NSString stringWithFormat:@"%.1f", self.axsTweakKitSlider.value];
    self.axsTweakKitValueLabel.text = value;
    self.axsTweakKitSlider.accessibilityValue = value;
}

#pragma mark - Events

- (void)axsTweakKit_sliderMoved:(UISlider *)sender {
    [self axsTweakKit_updateValueLabel];
    // VoiceOver adjustments do not necessarily emit touch-up events.
    if (UIAccessibilityIsVoiceOverRunning()) {
        [self axsTweakKit_sliderCommitted:sender];
    }
}

- (void)axsTweakKit_sliderCommitted:(UISlider *)sender {
    [self axsTweakKit_updateValueLabel];
    id<AxsTweakKitSliderCellHandler> handler = self.axsTweakKitHandler;
    if (handler == nil) {
        return;
    }
    [handler axsTweakKit_setSliderValue:sender.value specifier:self.specifier];
}

@end