#import "AxsTweakKitPrefsRootListController.h"
#import "AxsTweakKitSliderCell.h"
#import "AxsTweakKitPrefsStore.h"

#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

#include <math.h>

@interface AxsTweakKitPrefsRootListController () <AxsTweakKitSliderCellHandler>
@end

@implementation AxsTweakKitPrefsRootListController

#pragma mark - Rows

- (NSArray *)specifiers {
    // Cached in the framework's own ivar, so showing the pane a second time
    // reloads instead of keeping a stale array.
    if (_specifiers == nil) {
        _specifiers = [self loadSpecifiersFromPlistName:@"AxsTweakKitRoot" target:self];
    }
    return _specifiers;
}

- (void)tableView:(UITableView *)tableView
      willDisplayCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)indexPath {
    // PSListController's hierarchy does not have to implement this delegate
    // method; calling super blindly is an unrecognised selector.
    if ([PSListController instancesRespondToSelector:_cmd]) {
        [super tableView:tableView willDisplayCell:cell forRowAtIndexPath:indexPath];
    }
    if ([cell isKindOfClass:[AxsTweakKitSliderCell class]]) {
        AxsTweakKitSliderCell *sliderCell = (AxsTweakKitSliderCell *)cell;
        // Re-attached on every display; the property is weak.
        sliderCell.axsTweakKitHandler = self;
        [sliderCell axsTweakKit_reloadState];
    }
}

#pragma mark - Storage

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length == 0) {
        return nil;
    }
    id stored = [AxsTweakKitPrefsStore axsTweakKitValues][key];
    return stored ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length == 0) {
        return;
    }
    NSError *error = nil;
    if (![AxsTweakKitPrefsStore axsTweakKitWriteValue:value forKey:key error:&error]) {
        // Never let the control look saved when the file did not change.
        [self axsTweakKit_presentSaveError:error];
        [self reloadSpecifiers];
    }
}

- (void)axsTweakKit_presentSaveError:(NSError *)error {
    void (^present)(void) = ^{
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"设置未保存"
                             message:error.localizedDescription ?: @"请检查配置文件路径和写入权限。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    };
    if ([NSThread isMainThread]) {
        present();
    } else {
        dispatch_async(dispatch_get_main_queue(), present);
    }
}

#pragma mark - Slider

- (double)axsTweakKit_sliderValueForSpecifier:(PSSpecifier *)specifier {
    id value = [self readPreferenceValue:specifier];
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0.0;
}

- (void)axsTweakKit_setSliderValue:(double)value specifier:(PSSpecifier *)specifier {
    double minimum = [[specifier propertyForKey:@"min"] doubleValue];
    double maximum = [[specifier propertyForKey:@"max"] doubleValue];
    if (!isfinite(minimum)) minimum = 0.0;
    if (!isfinite(maximum) || maximum <= minimum) maximum = minimum + 1.0;
    if (!isfinite(value)) value = minimum;
    // The stored value is clamped here; the tweak clamps again on read.
    [self setPreferenceValue:@(fmax(minimum, fmin(maximum, value))) specifier:specifier];
}

@end