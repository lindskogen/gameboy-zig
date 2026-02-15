#import <GameController/GameController.h>

typedef struct {
    // Buttons
    int a, b, x, y;
    int start, select;
    int dpad_up, dpad_down, dpad_left, dpad_right;
    int l_shoulder, r_shoulder;
    // Axes
    float left_x, left_y;
    // Connected
    int connected;
} GamepadState;

void pollMacOSGamepad(GamepadState *state) {
    @autoreleasepool {
        state->connected = 0;

        NSArray<GCController *> *controllers = [GCController controllers];
        if (controllers.count == 0) return;

        GCController *controller = controllers[0];
        GCExtendedGamepad *gamepad = controller.extendedGamepad;
        if (!gamepad) return;

        state->connected = 1;

        state->a = gamepad.buttonA.pressed ? 1 : 0;
        state->b = gamepad.buttonB.pressed ? 1 : 0;
        state->x = gamepad.buttonX.pressed ? 1 : 0;
        state->y = gamepad.buttonY.pressed ? 1 : 0;

        state->start = gamepad.buttonMenu.pressed ? 1 : 0;
        state->select = gamepad.buttonOptions.pressed ? 1 : 0;

        state->dpad_up = gamepad.dpad.up.pressed ? 1 : 0;
        state->dpad_down = gamepad.dpad.down.pressed ? 1 : 0;
        state->dpad_left = gamepad.dpad.left.pressed ? 1 : 0;
        state->dpad_right = gamepad.dpad.right.pressed ? 1 : 0;

        state->l_shoulder = gamepad.leftShoulder.pressed ? 1 : 0;
        state->r_shoulder = gamepad.rightShoulder.pressed ? 1 : 0;

        state->left_x = gamepad.leftThumbstick.xAxis.value;
        state->left_y = gamepad.leftThumbstick.yAxis.value;
    }
}

const char* getControllerName(void) {
    @autoreleasepool {
        NSArray<GCController *> *controllers = [GCController controllers];
        if (controllers.count == 0) return NULL;
        return [controllers[0].vendorName UTF8String];
    }
}
