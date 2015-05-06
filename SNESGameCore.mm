/*
 Copyright (c) 2009, OpenEmu Team


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

#import "SNESGameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import <OpenGL/gl.h>

#include "memmap.h"
#include "pixform.h"
#include "gfx.h"
#include "display.h"
#include "ppu.h"
#include "apu.h"
#include "controls.h"
#include "snes9x.h"
#include "movie.h"
#include "snapshot.h"
#include "screenshot.h"
#include "cheats.h"
#import "OESNESSystemResponderClient.h"

#define SAMPLERATE      32000
#define SIZESOUNDBUFFER SAMPLERATE / 50 * 4

@interface SNESGameCore () <OESNESSystemResponderClient>
{
    UInt16        *soundBuffer;
    unsigned char *videoBuffer;
}

@end

static __weak SNESGameCore *_current;
@implementation SNESGameCore

NSString *SNESEmulatorKeys[] = { @"Up", @"Down", @"Left", @"Right", @"A", @"B", @"X", @"Y", @"L", @"R", @"Start", @"Select", nil };

- (oneway void)didPushSNESButton:(OESNESButton)button forPlayer:(NSUInteger)player;
{
    S9xReportButton((player << 16) | button, true);
}

- (oneway void)didReleaseSNESButton:(OESNESButton)button forPlayer:(NSUInteger)player;
{
    S9xReportButton((player << 16) | button, false);
}

- (void)mapButtons
{
    for(int player = 1; player <= 8; player++)
    {
        NSUInteger playerMask = player << 16;

        NSString *playerString = [NSString stringWithFormat:@"Joypad%d ", player];

        for(NSUInteger idx = 0; idx < OESNESButtonCount; idx++)
        {
            s9xcommand_t cmd = S9xGetCommandT([[playerString stringByAppendingString:SNESEmulatorKeys[idx]] UTF8String]);
            S9xMapButton(playerMask | idx, cmd, false);
        }
    }
}

#pragma mark Exectuion

- (void)executeFrame
{
    [self executeFrameSkippingFrame:NO];
}

- (void)executeFrameSkippingFrame:(BOOL)skip
{
    IPPU.RenderThisFrame = !skip;
    S9xMainLoop();
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    memset(&Settings, 0, sizeof(Settings));

    Settings.MouseMaster            = true;
    Settings.SuperScopeMaster       = true;
    Settings.MultiPlayer5Master     = true;
    Settings.JustifierMaster        = true;
    Settings.SixteenBitSound        = true;
    Settings.Stereo                 = true;
    Settings.SoundPlaybackRate      = SAMPLERATE;
    Settings.SoundInputRate         = 32000;
    Settings.SupportHiRes           = true;
    Settings.Transparency           = true;
    Settings.HDMATimingHack         = 100;
    Settings.BlockInvalidVRAMAccessMaster = true; // disabling may fix some homebrew or other games
    GFX.InfoString                  = NULL;
    GFX.InfoStringTimeout           = 0;
    Settings.DontSaveOopsSnapshot   = true;

    if(videoBuffer) free(videoBuffer);

    videoBuffer = (unsigned char *)malloc(MAX_SNES_WIDTH * MAX_SNES_HEIGHT * sizeof(uint16_t));

    GFX.Pitch = 512 * 2;
    GFX.Screen = (short unsigned int *)videoBuffer;

    S9xUnmapAllControls();

    [self mapButtons];

    S9xSetController(0, CTL_JOYPAD, 0, 0, 0, 0);
    S9xSetController(1, CTL_JOYPAD, 1, 0, 0, 0);

    if(!Memory.Init() || !S9xInitAPU() || !S9xGraphicsInit())
    {
        NSLog(@"Couldn't init");
        return NO;
    }

    NSLog(@"loading %@", path);

    /* buffer_ms : buffer size given in millisecond
     lag_ms    : allowable time-lag given in millisecond
     S9xInitSound(macSoundBuffer_ms, macSoundLagEnable ? macSoundBuffer_ms / 2 : 0); */
    if(!S9xInitSound(100, 0))
        NSLog(@"Couldn't init sound");
    
    S9xSetSamplesAvailableCallback(FinalizeSamplesAudioCallback, NULL);

    Settings.NoPatch = true;
    Settings.BSXBootup = false;

    if(Memory.LoadROM([path UTF8String]))
    {
        NSString *path = [NSString stringWithUTF8String:Memory.ROMFilename];
        NSString *extensionlessFilename = [[path lastPathComponent] stringByDeletingPathExtension];

        NSString *batterySavesDirectory = [self batterySavesDirectoryPath];

        if([batterySavesDirectory length] != 0)
        {
            [[NSFileManager defaultManager] createDirectoryAtPath:batterySavesDirectory withIntermediateDirectories:YES attributes:nil error:NULL];

            NSString *filePath = [batterySavesDirectory stringByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav"]];

            Memory.LoadSRAM([filePath UTF8String]);
        }

        return YES;
    }

    return NO;
}

bool8 S9xOpenSoundDevice(void)
{
	return true;
}

static void FinalizeSamplesAudioCallback(void *)
{
    GET_CURRENT_AND_RETURN();
    
    S9xFinalizeSamples();
    int samples = S9xGetSampleCount();
    S9xMixSamples((uint8_t*)current->soundBuffer, samples);
    [[current ringBufferAtIndex:0] write:current->soundBuffer maxLength:samples * 2];
}

#pragma mark Video

- (const void *)videoBuffer
{
    return GFX.Screen;
}

- (OEIntRect)screenRect
{
    return OEIntRectMake(0, 0, IPPU.RenderedScreenWidth, IPPU.RenderedScreenHeight);
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(MAX_SNES_WIDTH, MAX_SNES_HEIGHT);
}

- (void)setupEmulation
{
    if(soundBuffer) free(soundBuffer);

    soundBuffer = (UInt16 *)malloc(SIZESOUNDBUFFER * sizeof(UInt16));
    memset(soundBuffer, 0, SIZESOUNDBUFFER * sizeof(UInt16));
}

- (void)resetEmulation
{
    S9xSoftReset();
}

- (void)stopEmulation
{
    NSString *path = [NSString stringWithUTF8String:Memory.ROMFilename];
    NSString *extensionlessFilename = [[path lastPathComponent] stringByDeletingPathExtension];

    NSString *batterySavesDirectory = [self batterySavesDirectoryPath];

    if([batterySavesDirectory length] != 0)
    {

        [[NSFileManager defaultManager] createDirectoryAtPath:batterySavesDirectory withIntermediateDirectories:YES attributes:nil error:NULL];

        NSLog(@"Trying to save SRAM");

        NSString *filePath = [batterySavesDirectory stringByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav"]];

        Memory.SaveSRAM([filePath UTF8String]);
    }

    [super stopEmulation];
}

- (id)init
{
    if((self = [super init]))
    {
        _current = self;
    }
    
    return self;
}

- (void)dealloc
{
    free(videoBuffer);
    free(soundBuffer);
}

- (GLenum)pixelFormat
{
    return GL_RGB;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_SHORT_5_6_5;
}

- (GLenum)internalPixelFormat
{
    return GL_RGB5;
}

- (double)audioSampleRate
{
    return 32040.5;
}

- (NSTimeInterval)frameInterval
{
    return Settings.PAL ? 50 : 60.098;
}

- (NSUInteger)channelCount
{
    return 2;
}

- (BOOL)saveStateToFileAtPath: (NSString *) fileName
{
    return S9xFreezeGame([fileName UTF8String]) ? YES : NO;
}

- (BOOL)loadStateFromFileAtPath: (NSString *) fileName
{
    return S9xUnfreezeGame([fileName UTF8String]) ? YES : NO;
}

#pragma mark - Cheats

NSMutableDictionary *cheatList = [[NSMutableDictionary alloc] init];

- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
    if (enabled)
        [cheatList setValue:@YES forKey:code];
    else
        [cheatList removeObjectForKey:code];
    
    S9xDeleteCheats();
    
    NSArray *multipleCodes = [[NSArray alloc] init];
    
    // Apply enabled cheats found in dictionary
    for (id key in cheatList)
    {
        if ([[cheatList valueForKey:key] isEqual:@YES])
        {
            // Handle multi-line cheats
            multipleCodes = [key componentsSeparatedByString:@"+"];
            for (NSString *singleCode in multipleCodes) {
                // Sanitize for PAR codes that might contain colons
                const char *cheatCode = [[singleCode stringByReplacingOccurrencesOfString:@":"
                                                                               withString:@""] UTF8String];
                uint32		address;
                uint8		byte;
                
                // Both will determine if valid cheat code or not
                S9xGameGenieToRaw(cheatCode, address, byte);
                S9xProActionReplayToRaw(cheatCode, address, byte);
                
                S9xAddCheat(true, true, address, byte);
            }
        }
    }
    
    Settings.ApplyCheats = true;
    S9xApplyCheats();
}

@end
