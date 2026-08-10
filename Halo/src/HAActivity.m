#import "Halo.h"

@implementation HAActivity

+ (instancetype)activityWithIdentifier:(NSString *)identifier title:(NSString *)title {
    HAActivity *a = [HAActivity new];
    a.identifier = identifier ?: @"";
    a.title = title ?: @"";
    a.priority = HAActivityPriorityNormal;
    a.duration = 3.0;
    a.progress = -1.0;   // negative == no progress bar
    a.expandable = NO;
    return a;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<HAActivity %@ p=%ld \"%@\">",
            self.identifier, (long)self.priority, self.title];
}

@end
