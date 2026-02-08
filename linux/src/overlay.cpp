#include "overlay.h"
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <cstdio>

static unsigned long alloc_color(Display* d, uint32_t rgb) {
    XColor c{};
    c.red = ((rgb >> 16) & 0xFF) * 257;
    c.green = ((rgb >> 8) & 0xFF) * 257;
    c.blue = (rgb & 0xFF) * 257;
    c.flags = DoRed | DoGreen | DoBlue;
    XAllocColor(d, DefaultColormap(d, DefaultScreen(d)), &c);
    return c.pixel;
}

Overlay::Overlay() {
    create();
}

Overlay::~Overlay() {
    std::lock_guard<std::mutex> lk(mu_);
    if (display_) {
        if (window_) XDestroyWindow(display_, window_);
        XCloseDisplay(display_);
    }
}

void Overlay::create() {
    display_ = XOpenDisplay(nullptr);
    if (!display_) {
        fprintf(stderr, "[Overlay] Cannot open X display\n");
        return;
    }

    colors_[0] = alloc_color(display_, 0xFF2020);
    colors_[1] = alloc_color(display_, 0xFFAA00);

    XSetWindowAttributes attrs{};
    attrs.override_redirect = True;
    attrs.background_pixel = colors_[0];

    window_ = XCreateWindow(display_, DefaultRootWindow(display_),
                            8, 8, size_, size_, 0,
                            CopyFromParent, InputOutput, CopyFromParent,
                            CWOverrideRedirect | CWBackPixel, &attrs);

    Atom wm_type = XInternAtom(display_, "_NET_WM_WINDOW_TYPE", False);
    Atom dock = XInternAtom(display_, "_NET_WM_WINDOW_TYPE_DOCK", False);
    XChangeProperty(display_, window_, wm_type, XA_ATOM, 32, PropModeReplace,
                    reinterpret_cast<unsigned char*>(&dock), 1);

    Atom wm_state = XInternAtom(display_, "_NET_WM_STATE", False);
    Atom above = XInternAtom(display_, "_NET_WM_STATE_ABOVE", False);
    Atom sticky = XInternAtom(display_, "_NET_WM_STATE_STICKY", False);
    Atom states[] = {above, sticky};
    XChangeProperty(display_, window_, wm_state, XA_ATOM, 32, PropModeReplace,
                    reinterpret_cast<unsigned char*>(states), 2);

    XFlush(display_);
    fprintf(stderr, "[Overlay] Created %dx%d window at (8, 8)\n", size_, size_);
}

void Overlay::show(int color_idx) {
    if (!display_ || !window_) return;
    XSetWindowBackground(display_, window_, colors_[color_idx]);
    XClearWindow(display_, window_);
    XMapRaised(display_, window_);
    XFlush(display_);
}

void Overlay::hide() {
    if (!display_ || !window_) return;
    XUnmapWindow(display_, window_);
    XFlush(display_);
}

void Overlay::set_state(State s) {
    std::lock_guard<std::mutex> lk(mu_);
    if (s == state_) return;
    state_ = s;

    switch (s) {
    case State::hidden:       hide(); break;
    case State::recording:    show(0); break;
    case State::transcribing: show(1); break;
    }
}
