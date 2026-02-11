#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#include <stdlib.h>

typedef void (*zig_audio_callback)(void* device_ptr, void* output, const void* input, unsigned int frame_count);

typedef struct {
    unsigned char data[512];
} zig_ma_device_config;

_Static_assert(sizeof(zig_ma_device_config) >= sizeof(ma_device_config), "zig_ma_device_config too small");

zig_ma_device_config zig_ma_device_config_playback(unsigned int sample_rate, zig_audio_callback callback, void* user_data) {
    zig_ma_device_config result;
    memset(&result, 0, sizeof(result));
    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format = ma_format_f32;
    cfg.playback.channels = 1;
    cfg.sampleRate = sample_rate;
    cfg.dataCallback = (ma_device_data_proc)callback;
    cfg.pUserData = user_data;
    memcpy(&result, &cfg, sizeof(cfg));
    return result;
}

ma_device* zig_ma_device_init(const zig_ma_device_config* config) {
    ma_device* device = (ma_device*)malloc(sizeof(ma_device));
    if (!device) return NULL;
    if (ma_device_init(NULL, (const ma_device_config*)config, device) != MA_SUCCESS) {
        free(device);
        return NULL;
    }
    return device;
}

void zig_ma_device_start(ma_device* device) {
    ma_device_start(device);
}

unsigned int zig_ma_device_get_sample_rate(ma_device* device) {
    return device->sampleRate;
}

void zig_ma_device_uninit(ma_device* device) {
    if (device) {
        ma_device_uninit(device);
        free(device);
    }
}
