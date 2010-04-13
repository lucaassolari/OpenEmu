/*
 Copyright (c) 2010, OpenEmu Team
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * Neither the name of the OpenEmu Team nor the
 names of its contributors may be used to endorse or promote products
 derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

// for speedz
#import <OpenGL/CGLMacro.h>


#import "OpenEmuHelperApp.h"
#import "NSString+UUID.h"

// Open Emu
#import "GameCore.h"
#import "GameAudio.h"
#import "OECorePlugin.h"
#import "NSApplication+OEHIDAdditions.h"

#define BOOL_STR(b) ((b) ? "YES" : "NO")


@implementation OpenEmuHelperApp

@synthesize doUUID;
@synthesize loadedRom, surfaceID;

#pragma mark -

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    DLog(@"");
    if([parentApplication isTerminated]) [self quitHelperTool];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    parentApplication = [[NSRunningApplication runningApplicationWithProcessIdentifier:getppid()] retain];
    [parentApplication addObserver:self forKeyPath:@"terminated" options:0xF context:NULL];
    
    // unique server name per plugin instance
    theConnection = [[NSConnection new] retain];
    [theConnection setRootObject:self];
    if ([theConnection registerName:[NSString stringWithFormat:@"com.openemu.OpenEmuHelper-%@", doUUID, nil]] == NO)
        NSLog(@"Error opening NSConnection - exiting");
    else
        NSLog(@"NSConnection Open");
}

- (void)setupGameCore
{
    [gameAudio setVolume:1.0];
    
    // init resources
    [self setupOpenGLOnScreen:[NSScreen mainScreen]];
    
    [self setupIOSurface];
    [self setupFBO];
    [self setupGameTexture];
    
    // being rendering
    [self setupTimer];
}

- (void)quitHelperTool
{
    [[NSApplication sharedApplication] terminate:nil];
}

- (byref GameCore *)gameCore
{
    return gameCore;
}

#pragma mark -
#pragma mark IOSurface and GL Render
- (void)setupOpenGLOnScreen:(NSScreen*) screen
{
    // init our fullscreen context.
    CGLPixelFormatAttribute attributes[] = {kCGLPFAAccelerated, kCGLPFADoubleBuffer, 0};
    
    CGLError err = kCGLNoError;
    CGLPixelFormatObj pf;
    GLint numPixelFormats = 0;
    
    NSLog(@"choosing pixel format");
    err = CGLChoosePixelFormat(attributes, &pf, &numPixelFormats);
    
    if(err != kCGLNoError)
    {
        NSLog(@"Error choosing pixel format %s", CGLErrorString(err));
        [[NSApplication sharedApplication] terminate:nil];
    }
    CGLRetainPixelFormat(pf);
    
    NSLog(@"creating context");
    
    err = CGLCreateContext(pf, NULL, &glContext);
    if(err != kCGLNoError)
    {
        NSLog(@"Error creating context %s", CGLErrorString(err));
        [[NSApplication sharedApplication] terminate:nil];
    }
    CGLRetainContext(glContext);
    
}

- (void)setupIOSurface
{
    // init our texture and IOSurface
    NSMutableDictionary* surfaceAttributes = [[NSMutableDictionary alloc] init];
    [surfaceAttributes setObject:[NSNumber numberWithBool:YES] forKey:(NSString*)kIOSurfaceIsGlobal];
    [surfaceAttributes setObject:[NSNumber numberWithUnsignedInteger:(NSUInteger)gameCore.screenWidth] forKey:(NSString*)kIOSurfaceWidth];
    [surfaceAttributes setObject:[NSNumber numberWithUnsignedInteger:(NSUInteger)gameCore.screenHeight] forKey:(NSString*)kIOSurfaceHeight];
    [surfaceAttributes setObject:[NSNumber numberWithUnsignedInteger:(NSUInteger)4] forKey:(NSString*)kIOSurfaceBytesPerElement];
    
    // TODO: do we need to ensure openGL Compatibility and CALayer compatibility?
    
    surfaceRef = IOSurfaceCreate((CFDictionaryRef) surfaceAttributes);
    [surfaceAttributes release];
    
    // make a new texture.
    CGLContextObj cgl_ctx = glContext;
    
    glGenTextures(1, &ioSurfaceTexture);
    glEnable(GL_TEXTURE_RECTANGLE_ARB);
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, ioSurfaceTexture);
    
    // TODO: this is probably not right to rely on screenWidth/height.
    // for example Nestopia's returned values depend on NTSC being enabled or not.
    // we should probably have some sort of gameCore protocol for maxWidth maxHeight possible, and render into a sub-section of that.
    CGLError err = CGLTexImageIOSurface2D(glContext, GL_TEXTURE_RECTANGLE_ARB, GL_RGBA8, (GLsizei)gameCore.screenWidth, (GLsizei) gameCore.screenHeight, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, surfaceRef, 0);
    if(err != kCGLNoError)
    {
        NSLog(@"Error creating IOSurface texture: %s & %x", CGLErrorString(err), glGetError());
    }
    glFlush();
}

// make an FBO and bind out IOSurface backed texture to it
- (void)setupFBO
{
    DLog(@"creating FBO");
    
    GLenum status;
    
    CGLContextObj cgl_ctx = glContext;
    
    // Create temporary FBO to render in texture
    glGenFramebuffersEXT(1, &gameFBO);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, gameFBO);
    glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_TEXTURE_RECTANGLE_EXT, ioSurfaceTexture, 0);
    
    status = glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT);
    if(status != GL_FRAMEBUFFER_COMPLETE_EXT)
    {
        NSLog(@"Cannot create FBO");
        NSLog(@"OpenGL error %04X", status);
        
        glDeleteFramebuffersEXT(1, &gameFBO);
    }
}

- (void)setupGameTexture
{
    GLenum status;
    
    CGLContextObj cgl_ctx = glContext;
    
    glEnable(GL_TEXTURE_RECTANGLE_EXT);
    // create our texture
    glGenTextures(1, &gameTexture);
    glBindTexture(GL_TEXTURE_RECTANGLE_EXT, gameTexture);
    
    status = glGetError();
    if(status)
    {
        NSLog(@"createNewTexture, after bindTex: OpenGL error %04X", status);
    }
    
    // with storage hints & texture range -- assuming image depth should be 32 (8 bit rgba + 8 bit alpha ?)
    glTextureRangeAPPLE(GL_TEXTURE_RECTANGLE_EXT,  [gameCore bufferWidth] * [gameCore bufferHeight] * 4, [gameCore videoBuffer]);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_STORAGE_HINT_APPLE , GL_STORAGE_CACHED_APPLE);
    glPixelStorei(GL_UNPACK_CLIENT_STORAGE_APPLE, GL_TRUE);
    
    // proper tex params.
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    
    glTexImage2D( GL_TEXTURE_RECTANGLE_EXT, 0, [gameCore internalPixelFormat], [gameCore bufferWidth], [gameCore bufferHeight], 0, [gameCore pixelFormat], [gameCore pixelType], [gameCore videoBuffer]);
    
    status = glGetError();
    if(status)
    {
        NSLog(@"createNewTexture, after creating tex: OpenGL error %04X", status);
        glDeleteTextures(1, &gameTexture);
        gameTexture = 0;
    }
    
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_STORAGE_HINT_APPLE , GL_STORAGE_PRIVATE_APPLE);
    glPixelStorei(GL_UNPACK_CLIENT_STORAGE_APPLE, GL_FALSE);
    
}

- (void)setupTimer
{
    // CVDisplaylink at some point?
    timer = [NSTimer scheduledTimerWithTimeInterval: (NSTimeInterval) 1/60
                                             target: self
                                           selector: @selector(render)
                                           userInfo: nil
                                            repeats: YES];
}

- (void)render
{
    if([parentApplication isTerminated]) [self quitHelperTool];
    
    if([gameCore frameFinished])
    {
        [self updateGameTexture];
        [self correctPixelAspectRatio];
    }
}

- (void)updateGameTexture
{
    CGLContextObj cgl_ctx = glContext;
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, gameTexture);
    glTexSubImage2D(GL_TEXTURE_RECTANGLE_EXT, 0, 0, 0, [gameCore bufferWidth], [gameCore bufferHeight], [gameCore pixelFormat], [gameCore pixelType], [gameCore videoBuffer]);
}

- (void)correctPixelAspectRatio
{
    // the size of our output image, we may need/want to put in accessors for texture coord
    // offsets from the game core should the image we want be 'elsewhere' within the main texture.
    CGRect cropRect = [gameCore sourceRect];
    
    CGLContextObj cgl_ctx = glContext;
    
    // bind our FBO / and thus our IOSurface
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, gameFBO);
    
    // Assume FBOs JUST WORK, because we checked on startExecution
    //GLenum status = glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT);
    //if(status == GL_FRAMEBUFFER_COMPLETE_EXT)
    {
        // Setup OpenGL states
        glViewport(0, 0, gameCore.screenWidth,  gameCore.screenHeight);
        glMatrixMode(GL_PROJECTION);
        glPushMatrix();
        glLoadIdentity();
        glOrtho(0, gameCore.screenWidth, 0, gameCore.screenHeight, -1, 1);
        
        glMatrixMode(GL_MODELVIEW);
        glPushMatrix();
        glLoadIdentity();
        
        // dont bother clearing. we dont have any alpha so we just write over the buffer contents. saves us an expensive write.
        glClearColor(0.0, 0.0, 0.0, 0.0);
        glClear(GL_COLOR_BUFFER_BIT);
        
        glActiveTexture(GL_TEXTURE0);
        glEnable(GL_TEXTURE_RECTANGLE_EXT);
        glBindTexture(GL_TEXTURE_RECTANGLE_EXT, gameTexture);
        
        // do a nearest linear interp.
        glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        
        glColor4f(1.0, 1.0, 1.0, 1.0);
        
        // why do we need it ?
        glDisable(GL_BLEND);
        
        
        // flip the image here to correct for flippedness from the core.
        glBegin(GL_QUADS);    // Draw A Quad
        {
            glMultiTexCoord2f(GL_TEXTURE0, cropRect.origin.x, cropRect.size.height + cropRect.origin.y);
            glVertex3f(0.0f, 0.0f, 0.0f);
            
            glMultiTexCoord2f(GL_TEXTURE0, cropRect.size.width + cropRect.origin.x, cropRect.size.height + cropRect.origin.y);
            glVertex3f(gameCore.screenWidth, 0.0f, 0.0f);
            
            glMultiTexCoord2f(GL_TEXTURE0, cropRect.size.width + cropRect.origin.x, cropRect.origin.y);
            glVertex3f(gameCore.screenWidth, gameCore.screenHeight, 0.0f);
            
            glMultiTexCoord2f(GL_TEXTURE0, cropRect.origin.x, cropRect.origin.y);
            glVertex3f(0.0f, gameCore.screenHeight, 0.0f);
        }
        glEnd(); // Done Drawing The Quad
        
        // Restore OpenGL states
        glMatrixMode(GL_MODELVIEW);
        glPopMatrix();
        
        glMatrixMode(GL_PROJECTION);
        glPopMatrix();
    }
    
    // flush to make sure IOSurface updates are seen in parent app.
    glFlushRenderAPPLE();
    
    // get the updated surfaceID to pass to STDOut...
    surfaceID = IOSurfaceGetID(surfaceRef);
}

- (void)destroySurface
{
    CFRelease(surfaceRef);
    surfaceRef = nil;
    
    CGLContextObj cgl_ctx = glContext;
    
    glDeleteTextures(1, &ioSurfaceTexture);
    glDeleteTextures(1, &gameTexture);
    glDeleteFramebuffersEXT(1, &gameFBO);
    
    glFlush();
}

#pragma mark -
#pragma mark Game Core methods

- (BOOL)loadRomAtPath:(NSString *)aPath withCorePluginAtPath:(NSString *)pluginPath gameCore:(out GameCore **)createdCore
{
    aPath = [aPath stringByStandardizingPath];
    BOOL isDir;
    
    DLog(@"New ROM path is: %@", aPath);
    
    if([[NSFileManager defaultManager] fileExistsAtPath:aPath isDirectory:&isDir] && !isDir)
    {
        NSString *extension = [aPath pathExtension];
        DLog(@"extension is: %@", extension);
        
        // cleanup
        if(self.loadedRom)
        {
            [gameCore stopEmulation];
            [gameAudio stopAudio];
            [gameCore release];
            [gameAudio release];
            
            DLog(@"released/cleaned up for new ROM");
        }
        self.loadedRom = NO;
        
        gameCore = [[[OECorePlugin corePluginWithBundleAtPath:pluginPath] controller] newGameCore];
        
        if(createdCore != NULL) *createdCore = gameCore;
        
        DLog(@"Loaded bundle. About to load rom...");
        
        if([gameCore loadFileAtPath:aPath])
        {
            DLog(@"Loaded new Rom: %@", aPath);
            return self.loadedRom = YES;
        }
        else
        {
            NSLog(@"ROM did not load.");
            if(createdCore != NULL) *createdCore = nil;
            [gameCore release];
        }
    }
    else NSLog(@"bad ROM path or filename");
    return NO;
}

- (void)setupEmulation
{
    [gameCore setupEmulation];
    
    // audio!
    gameAudio = [[GameAudio alloc] initWithCore:gameCore];
    DLog(@"initialized audio");
    
    // starts the threaded emulator timer
    [gameCore startEmulation];
    
    DLog(@"About to start audio");
    [gameAudio startAudio];
    
    [self setupGameCore];
    
    DLog(@"finished starting rom");
}

#pragma mark -
#pragma mark OE DO Delegate methods

// gamecore attributes
- (NSUInteger)screenWidth
{
    return [gameCore screenWidth];
}

- (NSUInteger)screenHeight
{
    return [gameCore screenHeight];
}

- (NSUInteger)bufferWidth
{
    return [gameCore bufferWidth];
}

- (NSUInteger)bufferHeight
{
    return [gameCore bufferHeight];
}

- (CGRect)sourceRect
{
    return [gameCore sourceRect];
}

- (BOOL)isEmulationPaused
{
    return [gameCore isEmulationPaused];
}

// methods
- (void)setVolume:(float)volume
{
    [gameAudio setVolume:volume];
    
}

- (NSPoint) mousePosition
{
    return [gameCore mousePosition];
}

- (void)setMousePosition:(NSPoint)pos
{
    [gameCore setMousePosition:pos];
}

- (void)setPauseEmulation:(BOOL)paused
{
    if(paused)
    {
        [gameAudio pauseAudio];
        [gameCore setPauseEmulation:YES];
    }
    else
    {
        [gameAudio startAudio];
        [gameCore setPauseEmulation:NO];
    }
}

- (void)player:(NSUInteger)playerNumber didPressButton:(OEButton)button
{
    NSLog(@"did Press Button");
    [gameCore player:playerNumber didPressButton:button];
}

- (void)player:(NSUInteger)playerNumber didReleaseButton:(OEButton)button
{
    NSLog(@"did Release Button");
    [gameCore player:playerNumber didReleaseButton:button];
}

@end

#pragma mark -
#pragma mark main

int main(int argc, const char * argv[])
{
    NSLog(@"Helper tool UUID is: %s", argv[1]);
    
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSApplication *app = [NSApplication sharedApplication];
    OpenEmuHelperApp *helper = [[OpenEmuHelperApp alloc] init];
    
    [app setDelegate:helper];
    [helper setDoUUID:[NSString stringWithUTF8String:argv[1]]];
    
    [app run];
    
    [app release];
    [helper release];
    [pool release];
    
    return 0;
}
