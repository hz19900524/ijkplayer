/*
 * IJKSDLGLView.m
 *
 * Copyright (c) 2013 Bilibili
 * Copyright (c) 2013 Zhang Rui <bbcallen@gmail.com>
 *
 * based on https://github.com/kolyvan/kxmovie
 *
 * This file is part of ijkPlayer.
 *
 * ijkPlayer is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * ijkPlayer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with ijkPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#import "IJKSDLGLView.h"
#import "ESCUIImageToDataTool.h"
#include "ijksdl/ijksdl_timer.h"
#include "ijksdl/ios/ijksdl_ios.h"
#include "ijksdl/ijksdl_gles2.h"
#include "ijksdl_image_convert.h"
typedef NS_ENUM(NSInteger, IJKSDLGLViewApplicationState) {
    IJKSDLGLViewApplicationUnknownState = 0,
    IJKSDLGLViewApplicationForegroundState = 1,
    IJKSDLGLViewApplicationBackgroundState = 2
};

@interface IJKSDLGLView()
@property(atomic,strong) NSRecursiveLock *glActiveLock;
@property(atomic) BOOL glActivePaused;
@end

@implementation IJKSDLGLView {
    EAGLContext     *_context;
    GLuint          _framebuffer;
    GLuint          _renderbuffer;
    GLint           _backingWidth;
    GLint           _backingHeight;

    int             _frameCount;
    
    int64_t         _lastFrameTime;

    IJK_GLES2_Renderer *_renderer;
    int                 _rendererGravity;

    BOOL            _isRenderBufferInvalidated;

    int             _tryLockErrorCount;
    BOOL            _didSetupGL;
    BOOL            _didStopGL;
    BOOL            _didLockedDueToMovedToWindow;
    BOOL            _shouldLockWhileBeingMovedToWindow;
    NSMutableArray *_registeredNotifications;

    IJKSDLGLViewApplicationState _applicationState;
    Uint8 *pixels_3d[2];
}

@synthesize isThirdGLView= _isThirdGLView;
@synthesize scaleFactor = _scaleFactor;
@synthesize fps= _fps;
@synthesize showFrameIndex=_showFrameIndex;
@synthesize videoLeftFrame=_videoLeftFrame;
@synthesize videoRightFrame=_videoRightFrame;
@synthesize videosFramesArray=_videosFramesArray;
@synthesize timer=_timer;
@synthesize videoLeftMarkWater=_videoLeftMarkWater;
@synthesize videoRightMarkWater=_videoRightMarkWater;
+ (Class) layerClass
{
	return [CAEAGLLayer class];
}

- (id) initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _tryLockErrorCount = 0;
        _shouldLockWhileBeingMovedToWindow = YES;
        self.glActiveLock = [[NSRecursiveLock alloc] init];
        _registeredNotifications = [[NSMutableArray alloc] init];
        [self registerApplicationObservers];

        _didSetupGL = NO;
        if ([self isApplicationActive] == YES)
            [self setupGLOnce];
    }
    self.backgroundColor=[UIColor blackColor];
    return self;
}

- (void)willMoveToWindow:(UIWindow *)newWindow
{
    if (!_shouldLockWhileBeingMovedToWindow) {
        [super willMoveToWindow:newWindow];
        return;
    }
    if (newWindow && !_didLockedDueToMovedToWindow) {
        [self lockGLActive];
        _didLockedDueToMovedToWindow = YES;
    }
    [super willMoveToWindow:newWindow];
}

- (void)didMoveToWindow
{
    [super didMoveToWindow];
    if (self.window && _didLockedDueToMovedToWindow) {
        [self unlockGLActive];
        _didLockedDueToMovedToWindow = NO;
    }
}

- (BOOL)setupEAGLContext:(EAGLContext *)context
{
    glGenFramebuffers(1, &_framebuffer);
    glGenRenderbuffers(1, &_renderbuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _renderbuffer);
    [_context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer*)self.layer];
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_backingWidth);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_backingHeight);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _renderbuffer);

    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        NSLog(@"failed to make complete framebuffer object %x\n", status);
        return NO;
    }

    GLenum glError = glGetError();
    if (GL_NO_ERROR != glError) {
        NSLog(@"failed to setup GL %x\n", glError);
        return NO;
    }

    return YES;
}

- (CAEAGLLayer *)eaglLayer
{
    return (CAEAGLLayer*) self.layer;
}

- (BOOL)setupGL
{
    if (_didSetupGL)
        return YES;

    CAEAGLLayer *eaglLayer = (CAEAGLLayer*) self.layer;
    eaglLayer.opaque = YES;
    eaglLayer.drawableProperties = [NSDictionary dictionaryWithObjectsAndKeys:
                                    [NSNumber numberWithBool:NO], kEAGLDrawablePropertyRetainedBacking,
                                    kEAGLColorFormatRGBA8, kEAGLDrawablePropertyColorFormat,
                                    nil];

    _scaleFactor = [[UIScreen mainScreen] scale];
    if (_scaleFactor < 0.1f)
        _scaleFactor = 1.0f;

    [eaglLayer setContentsScale:_scaleFactor];

    _context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    if (_context == nil) {
        NSLog(@"failed to setup EAGLContext\n");
        return NO;
    }

    EAGLContext *prevContext = [EAGLContext currentContext];
    [EAGLContext setCurrentContext:_context];

    _didSetupGL = NO;
    if ([self setupEAGLContext:_context]) {
        NSLog(@"OK setup GL\n");
        _didSetupGL = YES;
    }

    [EAGLContext setCurrentContext:prevContext];
    return _didSetupGL;
}

- (BOOL)setupGLOnce
{
    if (_didSetupGL)
        return YES;

    if (![self tryLockGLActive])
        return NO;

    BOOL didSetupGL = [self setupGL];
    [self unlockGLActive];
    return didSetupGL;
}

- (BOOL)isApplicationActive
{
    switch (_applicationState) {
        case IJKSDLGLViewApplicationForegroundState:
            return YES;
        case IJKSDLGLViewApplicationBackgroundState:
            return NO;
        default: {
            UIApplicationState appState = [UIApplication sharedApplication].applicationState;
            switch (appState) {
                case UIApplicationStateActive:
                    return YES;
                case UIApplicationStateInactive:
                case UIApplicationStateBackground:
                default:
                    return NO;
            }
        }
    }
}

- (void)dealloc
{
    [self lockGLActive];

    _didStopGL = YES;
    EAGLContext *prevContext = [EAGLContext currentContext];
    [EAGLContext setCurrentContext:_context];
    
    IJK_GLES2_Renderer_reset(_renderer);
    IJK_GLES2_Renderer_freeP(&_renderer);

    if (_framebuffer) {
        glDeleteFramebuffers(1, &_framebuffer);
        _framebuffer = 0;
    }

    if (_renderbuffer) {
        glDeleteRenderbuffers(1, &_renderbuffer);
        _renderbuffer = 0;
    }

    glFinish();

    [EAGLContext setCurrentContext:prevContext];

    _context = nil;

    [self unregisterApplicationObservers];
    //加入的代码 start
    if (_timer) {
        [_timer invalidate];
        _timer=nil;
    }
    [_videoLeftFrame removeFromSuperview];
 
    [_videoRightFrame removeFromSuperview];
    if (pixels_3d[0]) {
        free(pixels_3d[0]);
    }
    if (pixels_3d[1]) {
        free(pixels_3d[1]);
    }
    [_videosFramesArray removeAllObjects];
    _videoLeftMarkWater=nil;
    _videoRightMarkWater=nil;
    _videoLeftFrame=nil;
    _videoRightFrame=nil;
    _videosFramesArray=nil;
    _showFrameIndex=0;
    //加入的代码 end
    [self unlockGLActive];
}

- (void)setScaleFactor:(CGFloat)scaleFactor
{
    _scaleFactor = scaleFactor;
    [self invalidateRenderBuffer];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    if (self.window.screen != nil) {
        _scaleFactor = self.window.screen.scale;
    }
    [self invalidateRenderBuffer];
}

- (void)setContentMode:(UIViewContentMode)contentMode
{
    [super setContentMode:contentMode];

    switch (contentMode) {
        case UIViewContentModeScaleToFill:
            _rendererGravity = IJK_GLES2_GRAVITY_RESIZE;
            break;
        case UIViewContentModeScaleAspectFit:
            _rendererGravity = IJK_GLES2_GRAVITY_RESIZE_ASPECT;
            break;
        case UIViewContentModeScaleAspectFill:
            _rendererGravity = IJK_GLES2_GRAVITY_RESIZE_ASPECT_FILL;
            break;
        default:
            _rendererGravity = IJK_GLES2_GRAVITY_RESIZE_ASPECT;
            break;
    }
    [self invalidateRenderBuffer];
}

- (BOOL)setupRenderer: (SDL_VoutOverlay *) overlay
{
    if (overlay == nil)
        return _renderer != nil;

    if (!IJK_GLES2_Renderer_isValid(_renderer) ||
        !IJK_GLES2_Renderer_isFormat(_renderer, overlay->format)) {

        IJK_GLES2_Renderer_reset(_renderer);
        IJK_GLES2_Renderer_freeP(&_renderer);

        _renderer = IJK_GLES2_Renderer_create(overlay);
        if (!IJK_GLES2_Renderer_isValid(_renderer))
            return NO;

        if (!IJK_GLES2_Renderer_use(_renderer))
            return NO;

        IJK_GLES2_Renderer_setGravity(_renderer, _rendererGravity, _backingWidth, _backingHeight);
    }

    return YES;
}

- (void)invalidateRenderBuffer
{
    NSLog(@"invalidateRenderBuffer\n");
    [self lockGLActive];

    _isRenderBufferInvalidated = YES;

    if ([[NSThread currentThread] isMainThread]) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            if (_isRenderBufferInvalidated)
                [self display:nil rotate_degrees:0];
        });
    } else {
        [self display:nil rotate_degrees:0];
    }

    [self unlockGLActive];
}

- (void) display_pixels: (IJKOverlay *) overlay rotate_degrees:(int)rotate_degrees{

        Uint8 *dst_data[1];
        static dispatch_once_t onceScale;
        static CGRect imageViewRect;
        dispatch_once(&onceScale, ^{
            CGRect screenBounds=[UIScreen mainScreen].bounds;
            CGSize screenSize=screenBounds.size;
            if (rotate_degrees==90||rotate_degrees==270) {
                if (screenSize.width>=screenSize.height) {
                    CGFloat imageViewRectWidth=screenSize.height*overlay->h/overlay->w;
                    CGFloat position_x=(screenSize.width - imageViewRectWidth)/2;
                    imageViewRect=CGRectMake(position_x, 0, imageViewRectWidth, screenSize.height);
                }else{
                    
                }
            }else{
                CGFloat width=screenSize.width;
                CGFloat height=screenSize.height;
                if (height > width / 16 * 9) {height = width / 16 * 9;}
                else{width = height / 9 * 16;}
                imageViewRect=CGRectMake((screenSize.width-width)/2, (screenSize.height-height)/2, width, height);
            }
        });
    [ESCUIImageToDataTool yuvDataConverteARGBDataWithYdata:overlay->pixels[0] udata:overlay->pixels[1] vdata:overlay->pixels[2] argbData:dst_data width:overlay->w height:overlay->h];
    UIImage* leftimage=nil;
    UIImage* rightImage=nil;
    UIImage* rotateImage=nil;
    int32_t dst_line_size = overlay->w * 2;
    int32_t src_line_size = overlay->w * 4;
    int32_t frameWidth=overlay->w;
    int32_t frameHeight=overlay->h;
    const uint8_t *src_pixels =dst_data[0];
    if (!pixels_3d[0]) {
        pixels_3d[0] = (uint8_t *) calloc(1, dst_line_size*overlay->h);
    }
    if (!pixels_3d[1]) {
        pixels_3d[1] = (uint8_t *) calloc(1, dst_line_size*overlay->h);
    }
    switch (rotate_degrees) {
        case 0:
            break;
        case 180:
            rotateImage=[ESCUIImageToDataTool rotateImage:[ESCUIImageToDataTool getImageFromRGBAData:dst_data[0]  width:overlay->w height:overlay->h] byDegrees:rotate_degrees];
            [ESCUIImageToDataTool getImageRGBADataWithImage:rotateImage rgbaData:dst_data[0]];
            rotateImage=nil;
            break;
        case 90:
        case 270:
            frameWidth=overlay->h;
            frameHeight=overlay->w;
            dst_line_size = overlay->h * 2;
            src_line_size = overlay->h * 4;
            rotateImage=[ESCUIImageToDataTool rotateImage:[ESCUIImageToDataTool getImageFromRGBAData:dst_data[0]  width:overlay->w height:overlay->h] byDegrees:rotate_degrees];
            [ESCUIImageToDataTool getImageRGBADataWithImage:rotateImage rgbaData:dst_data[0]];
            rotateImage=nil;
            break;
        default:
            break;
    }
    //左帧图像处理
    av_image_copy_plane(pixels_3d[0], dst_line_size, src_pixels,
                        src_line_size,
                        dst_line_size,
                        frameHeight);
    src_pixels += dst_line_size;
    //右帧图像处理
    av_image_copy_plane(pixels_3d[1], dst_line_size, src_pixels,
                        src_line_size,
                        dst_line_size,
                        frameHeight);
    
    if (!_videoLeftMarkWater) {
        _videoRightMarkWater=[UIImage imageNamed:@"yellow_256_elliptic"];
    }
    if (!_videoRightFrame) {
        _videoLeftMarkWater=[UIImage imageNamed:@"black_256_elliptic"];
    }
    leftimage=[ESCUIImageToDataTool mergeImages:[ESCUIImageToDataTool getImageFromRGBAData:pixels_3d[0]  width:frameWidth>>1 height:frameHeight] withImage:_videoLeftMarkWater];
    rightImage=[ESCUIImageToDataTool mergeImages:[ESCUIImageToDataTool getImageFromRGBAData:pixels_3d[1]  width:frameWidth>>1 height:frameHeight] withImage:_videoRightMarkWater];
    
    free(dst_data[0]);
    dst_data[0]=NULL;
    src_pixels=NULL;
    dispatch_sync(dispatch_get_main_queue(), ^{
            // 创建一个UIImageView实例，并设置其为myView的背景
            if (!_videoLeftFrame) {
                _videoLeftFrame = [[UIImageView alloc] initWithFrame:imageViewRect];
                // 如果你想确保图片填充整个UIView，可以设置UIImageView的contentMode属性
                _videoLeftFrame.contentMode = UIViewContentModeScaleToFill;
            }
            
            if (!_videoRightFrame) {
                _videoRightFrame = [[UIImageView alloc] initWithFrame:imageViewRect];
                // 如果你想确保图片填充整个UIView，可以设置UIImageView的contentMode属性
                _videoRightFrame.contentMode = UIViewContentModeScaleToFill;
            }
            if (!_videosFramesArray) {
                _videosFramesArray=[NSMutableArray array];
            }
            if (!_timer) {
                _timer=[NSTimer timerWithTimeInterval:0.016 target:self selector:@selector(frameSwapByTimer) userInfo:nil repeats:YES];
                // 将定时器加入运行循环
                [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
            }
            [_videosFramesArray addObject:leftimage];
            [_videosFramesArray addObject:rightImage];
            
        });
    return;
}

- (void)frameSwapByTimer {
    if (_videosFramesArray.count!=0&&_showFrameIndex==0) {
        _videoLeftFrame.image=_videosFramesArray[0];
        _videoRightFrame.image=_videosFramesArray[1];
        [_videosFramesArray removeAllObjects];
    }
    if (_showFrameIndex==0) {
        if (_videoLeftFrame) {
            [self addSubview:_videoLeftFrame];
        }
        if (_videoRightFrame) {
            [_videoRightFrame removeFromSuperview];
        }
        _showFrameIndex=1;
    }else{
        if (_videoRightFrame) {
            [self addSubview:_videoRightFrame];
        }
        if (_videoLeftFrame) {
            [_videoLeftFrame removeFromSuperview];
        }
        _showFrameIndex=0;
    }
}
 
- (void)display:(SDL_VoutOverlay *)overlay rotate_degrees:(int)rotate_degrees{
    if (_didSetupGL == NO)
        return;

    if ([self isApplicationActive] == NO)
        return;

    if (![self tryLockGLActive]) {
        if (0 == (_tryLockErrorCount % 100)) {
            NSLog(@"IJKSDLGLView:display: unable to tryLock GL active: %d\n", _tryLockErrorCount);
        }
        _tryLockErrorCount++;
        return;
    }

    _tryLockErrorCount = 0;
    if (_context && !_didStopGL) {
        EAGLContext *prevContext = [EAGLContext currentContext];
        [EAGLContext setCurrentContext:_context];
        [self displayInternal:overlay];
        [EAGLContext setCurrentContext:prevContext];
    }

    [self unlockGLActive];
}
// NOTE: overlay could be NULl
- (void)displayInternal: (SDL_VoutOverlay *) overlay
{
    if (![self setupRenderer:overlay]) {
        if (!overlay && !_renderer) {
            NSLog(@"IJKSDLGLView: setupDisplay not ready\n");
        } else {
            NSLog(@"IJKSDLGLView: setupDisplay failed\n");
        }
        return;
    }

    [[self eaglLayer] setContentsScale:_scaleFactor];

    if (_isRenderBufferInvalidated) {
        NSLog(@"IJKSDLGLView: renderbufferStorage fromDrawable\n");
        _isRenderBufferInvalidated = NO;

        glBindRenderbuffer(GL_RENDERBUFFER, _renderbuffer);
        [_context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer*)self.layer];
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_backingWidth);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_backingHeight);
        IJK_GLES2_Renderer_setGravity(_renderer, _rendererGravity, _backingWidth, _backingHeight);
    }

    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    glViewport(0, 0, _backingWidth, _backingHeight);

    if (!IJK_GLES2_Renderer_renderOverlay(_renderer, overlay))
        ALOGE("[EGL] IJK_GLES2_render failed\n");

    glBindRenderbuffer(GL_RENDERBUFFER, _renderbuffer);
    [_context presentRenderbuffer:GL_RENDERBUFFER];

    int64_t current = (int64_t)SDL_GetTickHR();
    int64_t delta   = (current > _lastFrameTime) ? current - _lastFrameTime : 0;
    if (delta <= 0) {
        _lastFrameTime = current;
    } else if (delta >= 1000) {
        _fps = ((CGFloat)_frameCount) * 1000 / delta;
        _frameCount = 0;
        _lastFrameTime = current;
    } else {
        _frameCount++;
    }
}

#pragma mark AppDelegate

- (void) lockGLActive
{
    [self.glActiveLock lock];
}

- (void) unlockGLActive
{
    [self.glActiveLock unlock];
}

- (BOOL) tryLockGLActive
{
    if (![self.glActiveLock tryLock])
        return NO;

    /*-
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive &&
        [UIApplication sharedApplication].applicationState != UIApplicationStateInactive) {
        [self.appLock unlock];
        return NO;
    }
     */

    if (self.glActivePaused) {
        [self.glActiveLock unlock];
        return NO;
    }
    
    return YES;
}

- (void)toggleGLPaused:(BOOL)paused
{
    [self lockGLActive];
    if (!self.glActivePaused && paused) {
        if (_context != nil) {
            EAGLContext *prevContext = [EAGLContext currentContext];
            [EAGLContext setCurrentContext:_context];
            glFinish();
            [EAGLContext setCurrentContext:prevContext];
        }
    }
    self.glActivePaused = paused;
    [self unlockGLActive];
}

- (void)registerApplicationObservers
{

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillEnterForeground)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
    [_registeredNotifications addObject:UIApplicationWillEnterForegroundNotification];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [_registeredNotifications addObject:UIApplicationDidBecomeActiveNotification];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    [_registeredNotifications addObject:UIApplicationWillResignActiveNotification];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [_registeredNotifications addObject:UIApplicationDidEnterBackgroundNotification];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillTerminate)
                                                 name:UIApplicationWillTerminateNotification
                                               object:nil];
    [_registeredNotifications addObject:UIApplicationWillTerminateNotification];
}

- (void)unregisterApplicationObservers
{
    for (NSString *name in _registeredNotifications) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:name object:nil];
    }
}
//当程序从后台将要重新回到前台（但是还没变成Active状态）时候调用
- (void)applicationWillEnterForeground
{
    NSLog(@"IJKSDLGLView:applicationWillEnterForeground: %d", (int)[UIApplication sharedApplication].applicationState);
    [self setupGLOnce];
    _applicationState = IJKSDLGLViewApplicationForegroundState;
    [self toggleGLPaused:NO];
}
//当应用即将进入前台运行时调用
- (void)applicationDidBecomeActive
{
    NSLog(@"IJKSDLGLView:applicationDidBecomeActive: %d", (int)[UIApplication sharedApplication].applicationState);
    [self setupGLOnce];
    [self toggleGLPaused:NO];
}
//当应用即将从前台退出时调用
- (void)applicationWillResignActive
{
    NSLog(@"IJKSDLGLView:applicationWillResignActive: %d", (int)[UIApplication sharedApplication].applicationState);
    [self toggleGLPaused:YES];
    glFinish();
}
//当应用开始在后台运行的时候调用
- (void)applicationDidEnterBackground
{
    NSLog(@"IJKSDLGLView:applicationDidEnterBackground: %d", (int)[UIApplication sharedApplication].applicationState);
    _applicationState = IJKSDLGLViewApplicationBackgroundState;
    [self toggleGLPaused:YES];
    glFinish();
}
//当应用即将被终止，在种终止前调用的函数。通常是用来保存数据和一些退出前的清理工作。如果应用当前处在suspended,此方法不会被调用。该方法最长运行时限为3秒，过期应用即被kill掉并且移除内存
- (void)applicationWillTerminate
{
    NSLog(@"IJKSDLGLView:applicationWillTerminate: %d", (int)[UIApplication sharedApplication].applicationState);
    [self toggleGLPaused:YES];
}

#pragma mark snapshot

- (UIImage*)snapshot
{
    [self lockGLActive];

    UIImage *image = [self snapshotInternal];

    [self unlockGLActive];

    return image;
}

- (UIImage*)snapshotInternal
{
    if (isIOS7OrLater()) {
        return [self snapshotInternalOnIOS7AndLater];
    } else {
        return [self snapshotInternalOnIOS6AndBefore];
    }
}

- (UIImage*)snapshotInternalOnIOS7AndLater
{
    if (CGSizeEqualToSize(self.bounds.size, CGSizeZero)) {
        return nil;
    }
    UIGraphicsBeginImageContextWithOptions(self.bounds.size, NO, 0.0);
    // Render our snapshot into the image context
    [self drawViewHierarchyInRect:self.bounds afterScreenUpdates:NO];

    // Grab the image from the context
    UIImage *complexViewImage = UIGraphicsGetImageFromCurrentImageContext();
    // Finish using the context
    UIGraphicsEndImageContext();

    return complexViewImage;
}

- (UIImage*)snapshotInternalOnIOS6AndBefore
{
    EAGLContext *prevContext = [EAGLContext currentContext];
    [EAGLContext setCurrentContext:_context];

    GLint backingWidth, backingHeight;

    // Bind the color renderbuffer used to render the OpenGL ES view
    // If your application only creates a single color renderbuffer which is already bound at this point,
    // this call is redundant, but it is needed if you're dealing with multiple renderbuffers.
    // Note, replace "viewRenderbuffer" with the actual name of the renderbuffer object defined in your class.
    glBindRenderbuffer(GL_RENDERBUFFER, _renderbuffer);

    // Get the size of the backing CAEAGLLayer
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &backingWidth);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &backingHeight);

    NSInteger x = 0, y = 0, width = backingWidth, height = backingHeight;
    NSInteger dataLength = width * height * 4;
    GLubyte *data = (GLubyte*)malloc(dataLength * sizeof(GLubyte));

    // Read pixel data from the framebuffer
    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    glReadPixels((int)x, (int)y, (int)width, (int)height, GL_RGBA, GL_UNSIGNED_BYTE, data);

    // Create a CGImage with the pixel data
    // If your OpenGL ES content is opaque, use kCGImageAlphaNoneSkipLast to ignore the alpha channel
    // otherwise, use kCGImageAlphaPremultipliedLast
    CGDataProviderRef ref = CGDataProviderCreateWithData(NULL, data, dataLength, NULL);
    CGColorSpaceRef colorspace = CGColorSpaceCreateDeviceRGB();
    CGImageRef iref = CGImageCreate(width, height, 8, 32, width * 4, colorspace, kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast,
                                    ref, NULL, true, kCGRenderingIntentDefault);

    [EAGLContext setCurrentContext:prevContext];

    // OpenGL ES measures data in PIXELS
    // Create a graphics context with the target size measured in POINTS
    UIGraphicsBeginImageContext(CGSizeMake(width, height));

    CGContextRef cgcontext = UIGraphicsGetCurrentContext();
    // UIKit coordinate system is upside down to GL/Quartz coordinate system
    // Flip the CGImage by rendering it to the flipped bitmap context
    // The size of the destination area is measured in POINTS
    CGContextSetBlendMode(cgcontext, kCGBlendModeCopy);
    CGContextDrawImage(cgcontext, CGRectMake(0.0, 0.0, width, height), iref);

    // Retrieve the UIImage from the current context
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    // Clean up
    free(data);
    CFRelease(ref);
    CFRelease(colorspace);
    CGImageRelease(iref);

    return image;
}

- (void)setShouldLockWhileBeingMovedToWindow:(BOOL)shouldLockWhileBeingMovedToWindow
{
    _shouldLockWhileBeingMovedToWindow = shouldLockWhileBeingMovedToWindow;
}
@end
