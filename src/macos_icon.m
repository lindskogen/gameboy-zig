#import <Cocoa/Cocoa.h>

void setDockIcon(const void *data, unsigned long len) {
    @autoreleasepool {
        NSData *nsdata = [NSData dataWithBytes:data length:len];
        NSImage *image = [[NSImage alloc] initWithData:nsdata];
        if (image) {
            [NSApp setApplicationIconImage:image];
        }
    }
}
