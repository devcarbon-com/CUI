/* iOS backend (iOS 11+). UIApplicationMain on the main thread owns UIKit
 * (window, view, touches, the hidden text field); the app's main() runs on a
 * second thread: the delegate launches it as cui_ios_user_main, apps rename
 * their main by including cui/cui_ios_main.h. Touches and keyboard text are
 * posted to a mutex-guarded queue and drained by cui__plat_wait on the app
 * thread, so all cui_input_* calls happen where the frames run. Touch maps
 * to the mouse (first finger = left button). GL is EAGLContext (GLES3) on
 * the view's CAEAGLLayer; the software renderer puts a CGImage on the layer.
 * Compile with -fobjc-arc. */
#include "cui_platform.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#include <dlfcn.h>
#include <pthread.h>
#include <unistd.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@class CUIIOSView;

int cui_ios_user_main(int argc, char **argv);

@interface CUIIOSPlat : NSObject <UIApplicationDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) CUIIOSView *view;
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) EAGLContext *gl;
@property (nonatomic, assign) cui_app *app;
@end

@interface CUIIOSView : UIView
@property (nonatomic, assign) cui_app *app;
@property (nonatomic, assign) unsigned int framebuffer;
@property (nonatomic, assign) unsigned int renderbuffer;
@end

/* set by the delegate once UIApplicationMain has built the window */
static CUIIOSPlat *cui__ios_plat;
static CUIIOSPlat *cui__ios_p(cui_app *app) { return app->plat ? (__bridge CUIIOSPlat *)app->plat : cui__ios_plat; }
int cui__ios_argc;
char **cui__ios_argv;

/* ---- pending input from the main thread, drained on the app thread ---- */

enum { CUIIOS_MOVE, CUIIOS_DOWN, CUIIOS_UP, CUIIOS_TEXT };

typedef struct cui__ios_event {
    int kind;
    float x, y;
    char utf8[16];
    struct cui__ios_event *next;
} cui__ios_event;

static pthread_mutex_t cui__ios_lock = PTHREAD_MUTEX_INITIALIZER;
static cui__ios_event *cui__ios_head, *cui__ios_tail;

static void cui__ios_post(cui__ios_event *e) {
    e->next = NULL;
    pthread_mutex_lock(&cui__ios_lock);
    if (cui__ios_tail) cui__ios_tail->next = e; else cui__ios_head = e;
    cui__ios_tail = e;
    pthread_mutex_unlock(&cui__ios_lock);
}

static void cui__ios_drain(cui_ctx *ui) {
    pthread_mutex_lock(&cui__ios_lock);
    cui__ios_event *list = cui__ios_head;
    cui__ios_head = cui__ios_tail = NULL;
    pthread_mutex_unlock(&cui__ios_lock);
    while (list) {
        cui__ios_event *e = list;
        list = e->next;
        switch (e->kind) {
        case CUIIOS_MOVE: cui_input_mouse_move(ui, e->x, e->y); break;
        case CUIIOS_DOWN:
            cui_input_mouse_move(ui, e->x, e->y);
            cui_input_mouse_button(ui, CUI_MOUSE_LEFT, true);
            break;
        case CUIIOS_UP:
            cui_input_mouse_move(ui, e->x, e->y);
            cui_input_mouse_button(ui, CUI_MOUSE_LEFT, false);
            break;
        case CUIIOS_TEXT: cui_input_text(ui, e->utf8); break;
        }
        free(e);
    }
}

double cui__plat_now(void) { return [[NSProcessInfo processInfo] systemUptime]; }
const char *cui__plat_name(void) { return "ios"; }

int cui__plat_system_dark(void) {
    if (@available(iOS 13.0, *))
        return [UITraitCollection currentTraitCollection].userInterfaceStyle == UIUserInterfaceStyleDark ? 1 : 0;
    return -1;
}

@implementation CUIIOSView
- (Class)layerClass { return [CAEAGLLayer class]; }

/* Touches arrive here via the responder chain — the app delegate never
 * receives them. */
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    (void)e;
    CGPoint p = [t.anyObject locationInView:self];
    cui__ios_event *ev = calloc(1, sizeof *ev);
    ev->kind = CUIIOS_DOWN; ev->x = (float)p.x; ev->y = (float)p.y;
    cui__ios_post(ev);
}
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    (void)e;
    CGPoint p = [t.anyObject locationInView:self];
    cui__ios_event *ev = calloc(1, sizeof *ev);
    ev->kind = CUIIOS_MOVE; ev->x = (float)p.x; ev->y = (float)p.y;
    cui__ios_post(ev);
}
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    (void)e;
    CGPoint p = [t.anyObject locationInView:self];
    cui__ios_event *ev = calloc(1, sizeof *ev);
    ev->kind = CUIIOS_UP; ev->x = (float)p.x; ev->y = (float)p.y;
    cui__ios_post(ev);
}
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    (void)t; (void)e;
    cui__ios_event *ev = calloc(1, sizeof *ev);
    ev->kind = CUIIOS_UP;
    cui__ios_post(ev);
}
@end

@implementation CUIIOSPlat

/* The hidden field takes soft-keyboard input; we swallow the characters it
 * would insert ourselves so the CUI text edit owns the text. */
- (BOOL)textField:(UITextField *)f shouldChangeCharactersInRange:(NSRange)r replacementString:(NSString *)s {
    (void)f; (void)r;
    if (s.length) {
        for (NSUInteger i = 0; i < s.length; ) {
            NSRange br = [s rangeOfComposedCharacterSequenceAtIndex:i];
            cui__ios_event *ev = calloc(1, sizeof *ev);
            ev->kind = CUIIOS_TEXT;
            NSString *sub = [s substringWithRange:br];
            [sub getBytes:ev->utf8 maxLength:sizeof ev->utf8 - 1 usedLength:NULL encoding:NSUTF8StringEncoding options:0 range:NSMakeRange(0, sub.length) remainingRange:NULL];
            ev->utf8[sizeof ev->utf8 - 1] = 0;
            cui__ios_post(ev);
            i += br.length;
        }
    }
    return NO;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application; (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    CUIIOSView *v = [[CUIIOSView alloc] initWithFrame:self.window.bounds];
    v.app = self.app;
    UIViewController *vc = [UIViewController new];
    vc.view = v;
    self.window.rootViewController = vc;
    self.view = v;
    self.field = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
    self.field.autocorrectionType = UITextAutocorrectionTypeNo;
    self.field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.field.delegate = self;
    [v addSubview:self.field];
    [self.window makeKeyAndVisible];
    cui__ios_plat = self;
    /* the app's main (renamed cui_ios_user_main) runs on its own thread */
    [NSThread detachNewThreadSelector:@selector(runUserMain) toTarget:self withObject:nil];
    return YES;
}

- (void)runUserMain {
    @autoreleasepool {
        cui_ios_user_main(cui__ios_argc, cui__ios_argv);
        /* the app loop is over: leave UIKit running so the process exits cleanly */
        exit(0);
    }
}

@end

/* The app includes cui/cui_ios_main.h, which renames its main to
 * cui_ios_user_main; this file provides the real main. */
extern int cui_ios_user_main(int argc, char **argv);

int main(int argc, char *argv[]) {
    cui__ios_argc = argc;
    cui__ios_argv = argv;
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([CUIIOSPlat class]));
    }
}

/* ---- GL: EAGLContext on the view's CAEAGLLayer ---- */

bool cui__plat_gl_create(cui_app *app, bool vsync) {
    (void)vsync;   /* presentRenderbuffer waits for the display, no interval knob */
    CUIIOSPlat *p = cui__ios_p(app);
    CUIIOSView *v = p.view;
    if (!v) return false;
    EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    if (!ctx || ![EAGLContext setCurrentContext:ctx]) return false;
    p.gl = ctx;
    CAEAGLLayer *layer = (CAEAGLLayer *)v.layer;
    /* On iOS Simulator CAEAGLLayer falls back to a plain CALayer (no EAGL);
     * drawableProperties then raises an unrecognized-selector exception. */
    if (![layer isKindOfClass:[CAEAGLLayer class]]) return false;
    layer.opaque = YES;
    layer.drawableProperties = @{ kEAGLDrawablePropertyRetainedBacking : @NO,
                                  kEAGLColorFormatRGBA8 : @YES };
    unsigned fb = 0, rb = 0;
    glGenFramebuffers(1, &fb);
    glBindFramebuffer(GL_FRAMEBUFFER, fb);
    glGenRenderbuffers(1, &rb);
    glBindRenderbuffer(GL_RENDERBUFFER, rb);
    [ctx renderbufferStorage:GL_RENDERBUFFER fromDrawable:layer];
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        glDeleteFramebuffers(1, &fb);
        glDeleteRenderbuffers(1, &rb);
        p.gl = nil;
        return false;
    }
    v.framebuffer = fb;
    v.renderbuffer = rb;
    return true;
}

void *cui__plat_gl_proc(const char *name) {
    return dlsym(RTLD_DEFAULT, name);   /* iOS links OpenGLES statically */
}

void cui__plat_gl_swap(cui_app *app) {
    CUIIOSPlat *p = cui__ios_p(app);
    if (p.gl) [p.gl presentRenderbuffer:GL_RENDERBUFFER];
}

void cui__plat_gl_release(cui_app *app) {
    CUIIOSPlat *p = cui__ios_p(app);
    CUIIOSView *v = p.view;
    if (v && v.framebuffer) {
        unsigned int fb = v.framebuffer, rb = v.renderbuffer;
        glDeleteFramebuffers(1, &fb);
        glDeleteRenderbuffers(1, &rb);
        v.framebuffer = v.renderbuffer = 0;
    }
    if (p.gl && [EAGLContext currentContext] == p.gl) [EAGLContext setCurrentContext:nil];
    p.gl = nil;
}

/* ---- software renderer: BGRA buffer -> CGImage -> layer ---- */

void cui__plat_present(cui_app *app, const void *bgra, int w, int h, int stride) {
    CUIIOSPlat *p = cui__ios_p(app);
    if (!p.view) return;
    @autoreleasepool {
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef ctx = CGBitmapContextCreate((void *)bgra, (size_t)w, (size_t)h, 8, (size_t)stride, cs,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        p.view.layer.contents = (__bridge id)img;
        p.view.layer.contentsScale = p.window.screen.scale;
        [CATransaction commit];
        if (img) CGImageRelease(img);
        if (ctx) CGContextRelease(ctx);
        CGColorSpaceRelease(cs);
    }
}

bool cui__plat_present_part(cui_app *app, const void *bgra, int w, int h, int stride, int x, int y, int pw, int ph) {
    (void)app; (void)bgra; (void)w; (void)h; (void)stride; (void)x; (void)y; (void)pw; (void)ph;
    return false;   /* the whole buffer is shown each time */
}

/* ---- metrics, title, native handle ---- */

void cui__plat_metrics(cui_app *app, float *w, float *h, float *scale, int *fb_w, int *fb_h) {
    CUIIOSPlat *p = cui__ios_p(app);
    CGRect b = p.view ? p.view.bounds : [UIScreen mainScreen].bounds;
    float s = (float)(p.window.screen ? p.window.screen.scale : [UIScreen mainScreen].scale);
    const char *env = getenv("CUI_SCALE");
    if (env) { float e = (float)atof(env); if (e > 0.25f && e < 8) s = e; }
    *w = (float)b.size.width;
    *h = (float)b.size.height;
    *scale = s;
    *fb_w = (int)(b.size.width * s + 0.5);
    *fb_h = (int)(b.size.height * s + 0.5);
}

void cui__plat_set_title(cui_app *app, const char *title) { (void)app; (void)title; }
void cui__plat_set_size(cui_app *app, int w, int h) { (void)app; (void)w; (void)h; }
void cui__plat_show(cui_app *app) { (void)app; }   /* the window is up before the app thread starts */
void *cui__plat_native(cui_app *app) { return (__bridge void *)cui__ios_p(app).window; }

double cui__plat_refresh_hz(cui_app *app) {
    (void)app;
    return (double)[UIScreen mainScreen].maximumFramesPerSecond;
}

static void cui__ios_text_input_rect(void *user, cui_rect caret) {
    (void)caret;
    /* show the soft keyboard the first time a text field wants a caret */
    static BOOL shown = NO;
    if (shown) return;
    shown = YES;
    CUIIOSPlat *p = cui__ios_p((cui_app *)user);
    UITextField *f = p.field;
    dispatch_async(dispatch_get_main_queue(), ^{ [f becomeFirstResponder]; });
}

/* ---- wait: give the app thread's time to the OS, then drain pending input ---- */

void cui__plat_wait(cui_app *app, double timeout) {
    if (timeout > 0) usleep((useconds_t)(timeout * 1e6));
    cui__ios_drain(app->ui);
}

/* ---- init / shutdown ---- */

bool cui__plat_init(cui_app *app) {
    /* UIApplicationMain runs on the main thread and builds the window; wait
     * for the delegate to have set it up, then adopt the platform object. */
    CUIIOSPlat *p = nil;
    for (int i = 0; i < 500 && !p; i++) {   /* up to ~5s */
        @autoreleasepool {
            p = (CUIIOSPlat *)cui__ios_plat;
            if (!p) usleep(10000);
        }
    }
    if (!p) return false;
    p.app = app;
    app->plat = (__bridge_retained void *)p;
    cui_platform_iface pi;
    memset(&pi, 0, sizeof pi);
    pi.user = app;
    pi.set_text_input_rect = cui__ios_text_input_rect;
    cui_set_platform(app->ui, &pi);
    return true;
}

void cui__plat_shutdown(cui_app *app) {
    if (!app->plat) return;
    CUIIOSPlat *p = (__bridge_transfer CUIIOSPlat *)app->plat;
    app->plat = NULL;
    cui__plat_gl_release(app);
    dispatch_async(dispatch_get_main_queue(), ^{
        p.window.hidden = YES;
        p.window = nil;
        p.view = nil;
        p.field = nil;
    });
}

#pragma clang diagnostic pop
