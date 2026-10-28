#pragma once

#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#include <math.h>

// The cell is a PSTableCell rather than PSSliderTableCell: PSSliderTableCell
// is a private, undocumented class whose own layout would fight the title /
// slider / value row below, and its init is not part of any supported header.
// The row is still a slider; only the cell it is drawn in is ours.
//
// It never stores a value itself: dragging updates the label, releasing
// commits through the handler, and the handler goes through the controller's
// setPreferenceValue:specifier:, so every control in the pane shares the one
// storage path.

@protocol AxsTweakKitSliderCellHandler <NSObject>
- (double)axsTweakKit_sliderValueForSpecifier:(PSSpecifier *)specifier;
- (void)axsTweakKit_setSliderValue:(double)value specifier:(PSSpecifier *)specifier;
@end

@interface AxsTweakKitSliderCell : PSTableCell
// Weak: a reused cell must not keep the controller alive.
@property (nonatomic, weak) id<AxsTweakKitSliderCellHandler> axsTweakKitHandler;
- (void)axsTweakKit_reloadState;
@end