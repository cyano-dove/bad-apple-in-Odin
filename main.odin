package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:c/libc"
import "core:strconv"
import "core:time"
import aud "vendor:miniaudio"

ALT_SCR_T  :: "\x1b[?1049h"
ALT_SCR_F  :: "\x1b[?1049l"
CUR_HIDE   :: "\x1b[?25l"
CUR_SHOW   :: "\x1b[?25h"
CLEAR      :: "\x1b[2J"
HOME       :: "\x1b[H" // move cursor to row 1, col 1
FPS :: 30
FRAME_TIME :: time.Second / FPS


printFileHex :: proc(data: []u8, stop: int = -1) {
    // unused
    buffer : [16]rune
    for value, index in data {
        if stop != -1 && index == stop {
            return
        }
        fmt.printf("%02x ", value)
        buffer[index%16] = rune(value)
        if (index+1) % 16 == 0 {
            fmt.printf("   |   ")
            for value, index in buffer {
                if value == 0 {
                    fmt.printf(" ")
                }
                else if value == 10 {
                    fmt.printf(" [nl] ")
                }
                else {
                    fmt.printf("%r", value)
                }
            }
            fmt.printf("\n")
        }
    }
}

getBoxheaders :: proc(data: []u8) {
    // unused (for now)
    boxSize : u32 = 0
    boxType : [4]rune
    subIndex : u32 = 0
    for value, index in data {
        // note: does not account for the case of an atom that exceed 2^32 bytes
        if subIndex < 4 {
            boxSize = (boxSize << 8) + u32(value)
        }
        if subIndex == 3 {
            fmt.printf("size: %d\n", boxSize)
        }
        if subIndex >= 4 && subIndex < 8 {
            boxType[subIndex-4] = rune(value)
        }
        if subIndex == 7 {
            fmt.printf("box type: %s\n", boxType)
        }
        if subIndex == boxSize - 1 && subIndex >= 7 {
            boxSize = 0
            subIndex = 0
            continue 
        }
        subIndex = subIndex + 1
    }
}


makeFramesFF :: proc(file: string, folder : string) {
    os.make_directory(folder)
    libc.system(fmt.ctprintf("ffmpeg -y -hide_banner -loglevel error -stats -i \"%s\" \"%s/%%04d.ppm\" -vn \"%s/audio.wav\"", file, folder, folder))
}

frameHeader :: proc(data: []u8, print := false) -> (off: int, w: int, h: int) {
    newLineCount : int = 0
    offset : int
    frameW : int
    frameH : int
    for value, index in data {
        if value == 10 {
            newLineCount = newLineCount + 1
        }
        if newLineCount == 1 && frameW == 0 {
            tempIndex := 1
            for ; data[tempIndex+index] != u8(' '); tempIndex += 1 {
                frameW = frameW * 10 + int(data[tempIndex+index]) - '0'
            }
            tempIndex += 1
            for ; data[tempIndex+index] != u8('\n'); tempIndex += 1 {
                frameH = frameH * 10 + int(data[tempIndex+index]) - '0'
            }
        }
        if newLineCount == 3 {
            offset = index
            break
        }
    }
    if print {
        fmt.printf("offset: %d | width: %d | height: %d", offset, frameW, frameH)
    }
    return offset, frameW, frameH
}

framePixelData :: proc(data: []u8) -> (pixels: []u8, w: int, h: int) {
    offset, width, height := frameHeader(data)
    r, g, b : u8
    pixel := make([]u8, width * height) // avg the r, g, b value into pixel's brightness

    for y in 0..<height {
        for x in 0..<width {
            p := y * width + x
            index := offset + 1 + p*3
            r = data[index    ]
            g = data[index + 1]
            b = data[index + 2]
            if (int(r) + int(g) + int(b)) / 3 > 128{
                pixel[p] = 255
            }
        }
    }
    return pixel, width, height
}

printFrame :: proc(pixel: []u8, width, height : int, setScrWidth := -1, setScrHeight := -1) {
    defer delete(pixel)
    scaleWidth : f32 = 1
    scaleHeight : f32 = 1
    scrWidth := width
    scrHeight := height
    if setScrWidth != -1 {
        scrWidth = min(setScrWidth, width)
        scaleWidth = f32(width) / f32(scrWidth)
    }
    if setScrHeight != -1 {
        scrHeight = min(setScrHeight, height)
        scaleHeight = f32(height) / f32(scrHeight)
    }
    
    str := strings.builder_make()
    defer strings.builder_destroy(&str)

    if scaleHeight == 1 && scaleWidth == 1 {
        // without scaling
        for y in 0..<height {
            for x in 0..<width {
                if pixel[y * width + x] == 255 {
                    strings.write_byte(&str, '#')
                }
                else {
                    strings.write_byte(&str, '.')
                }
            }
            strings.write_byte(&str, '\n') 
        }
    }
    else{
        // with scaling
        BRIGHTNESS := " .`',:;-~=+*#%$@" // shoutout to the C donut devblog https://www.a1k0n.net/2021/01/13/optimizing-donut.html
        for scrY in 0..<scrHeight {
            yStart := int(f32(scrY)     * scaleHeight)
            yEnd := int(f32(scrY + 1) * scaleHeight)
            for scrX in 0..<scrWidth {
                xStart := int(f32(scrX)     * scaleWidth)
                xEnd := int(f32(scrX + 1) * scaleWidth)
                sum := 0
                count := 0
                for y in yStart..<yEnd {
                    for x in xStart..<xEnd {
                        sum += int(pixel[y*width + x])
                        count += 1
                    }
                }
                strings.write_byte(&str, BRIGHTNESS[int(sum/count) / 17])
            }
            strings.write_byte(&str, '\n')  
        }
    }
    os.write_string(os.stdout, strings.to_string(str))
}

iterateFrames :: proc(folder : string, width : int, height : int) {
    engine : aud.engine
    result := aud.engine_init(nil, &engine)
    if result != .SUCCESS {
        fmt.println("could not start audio, press enter to continue: ", result)
        libc.getchar()
        return
    }
    defer aud.engine_uninit(&engine)
    aud.engine_play_sound(&engine, fmt.ctprintf("%s/audio.wav", folder), nil)
    
	os.write_string(os.stdout, ALT_SCR_T + CUR_HIDE + CLEAR)
	defer os.write_string(os.stdout, CUR_SHOW + ALT_SCR_F)

    startTime := time.tick_now()
    for n := 1; ; n += 1 {

        frame := fmt.tprintf("%s/%04d.ppm", folder, n)
        data, err := os.read_entire_file(frame, context.allocator)
        if err != nil {
            break
        }
        printFrame(framePixelData(data), width, height)
        delete(data)
        free_all(context.temp_allocator)
        os.write_string(os.stdout, HOME)

        nextFrame  := time.Duration(n) * FRAME_TIME
        elapsed := time.tick_since(startTime)
        if elapsed < nextFrame {
            time.sleep(nextFrame - elapsed)
        }
    }
}

main :: proc() {
    if len(os.args) < 2 {
        fmt.println("args: \"file\" width(optional) height(optional)")
        return
    }
    file := os.args[1]
    dot := strings.last_index_byte(file, '.')
    if dot == -1 {
        fmt.println("file needs an extension, e.g. video.mp4")
        return
    }
    folder := fmt.aprintf("%s_frames", file[:dot])
    defer delete(folder)
    width : int = -1
    height : int = -1
    if len(os.args) > 2 {
        width, _ = strconv.parse_int(os.args[2])
    }
    if len(os.args) > 3 {
        height, _ = strconv.parse_int(os.args[3])
    }

    makeFramesFF(file, folder)
    fmt.println("press enter to play")
    libc.getchar()


    iterateFrames(folder, width, height)

    libc.getchar()
}
