#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define MACVNC_MAX_DISPLAYS 16

typedef struct {
    uint32_t displayID;
    double logicalX;
    double logicalY;
    double logicalWidth;
    double logicalHeight;
    int pixelWidth;
    int pixelHeight;
} MacVNCDisplayInput;

typedef struct {
    MacVNCDisplayInput input;
    int framebufferX;
    int framebufferY;
} MacVNCDisplayGeometry;

typedef struct {
    size_t count;
    int width;
    int height;
    double logicalMinX;
    double logicalMinY;
    MacVNCDisplayGeometry displays[MACVNC_MAX_DISPLAYS];
} MacVNCDisplayLayout;

bool macVNCBuildDisplayLayout(const MacVNCDisplayInput *inputs,
                              size_t count,
                              MacVNCDisplayLayout *layout);

bool macVNCMapFramebufferPoint(const MacVNCDisplayLayout *layout,
                               int framebufferX,
                               int framebufferY,
                               double *globalX,
                               double *globalY,
                               uint32_t *displayID);
