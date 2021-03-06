

// Arduino bridge code between host computer and Dotstar-based digital
// addressable RGB LEDs (e.g. Adafruit product ID #1138).  LED data is
// streamed, not buffered, making this suitable for larger installations
// (e.g. video wall, etc.) than could otherwise be contained within the
// Arduino's limited RAM.  Intended for use with USB-native boards such
// as Teensy or Adafruit 32u4 Breakout; also works on normal serial
// Arduinos (Uno, etc.), but speed will be limited by the serial port.

// LED data and clock lines are connected to the Arduino's SPI output.
// On traditional Arduino boards (e.g. Uno), SPI data out is digital pin
// 11 and clock is digital pin 13.  On both Teensy and the 32u4 Breakout,
// data out is pin B2, clock is B1.  On Arduino Mega, 51=data, 52=clock.
// LEDs should be externally powered -- trying to run any more than just
// a few off the Arduino's 5V line is generally a Bad Idea.  LED ground
// should also be connected to Arduino ground.

// Elsewhere, the WS2801 version of this code was specifically designed
// to avoid buffer underrun conditions...the WS2801 pixels automatically
// latch when the data stream stops for 500 microseconds or more, whether
// intentional or not.  The LPD8806 pixels are fundamentally different --
// the latch condition is indicated within the data stream, not by pausing
// the clock -- and buffer underruns are therefore a non-issue.  In theory
// it would seem this could allow the code to be much simpler and faster
// (there's no need to sync up with a start-of-frame header), but in
// practice the difference was not as pronounced as expected -- such code
// soon ran up against a USB throughput limit anyway.  So, rather than
// break compatibility in the quest for speed that will never materialize,
// this code instead follows the same header format as the WS2801 version.
// This allows the same host-side code (e.g. Adalight, Adavision, etc.)
// to run with either type of LED pixels.  Huzzah!

// --------------------------------------------------------------------
//   This file is part of Adalight.

//   Adalight is free software: you can redistribute it and/or modify
//   it under the terms of the GNU Lesser General Public License as
//   published by the Free Software Foundation, either version 3 of
//   the License, or (at your option) any later version.

//   Adalight is distributed in the hope that it will be useful,
//   but WITHOUT ANY WARRANTY; without even the implied warranty of
//   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//   GNU Lesser General Public License for more details.

//   You should have received a copy of the GNU Lesser General Public
//   License along with Adalight.  If not, see
//   <http://www.gnu.org/licenses/>.
// --------------------------------------------------------------------

#include <SPI.h>
 #include <Adafruit_DotStar.h>
#ifdef __AVR__
  #include <avr/power.h>
#endif

 

// Parameter 1 = number of pixels in strip
// Parameter 2 = Arduino pin number (most are valid)
// Parameter 3 = pixel type flags, add together as needed:
//   NEO_KHZ800  800 KHz bitstream (most NeoPixel products w/WS2812 LEDs)
//   NEO_KHZ400  400 KHz (classic 'v1' (not v2) FLORA pixels, WS2811 drivers)
//   NEO_GRB     Pixels are wired for GRB bitstream (most NeoPixel products)
//   NEO_RGB     Pixels are wired for RGB bitstream (v1 FLORA pixels, not v2)
#define NUMPIXELS 30 // Number of LEDs in strip

// Here's how to control the LEDs from any two pins:
#define DATAPIN    4
#define CLOCKPIN   5
Adafruit_DotStar strip = Adafruit_DotStar(
  NUMPIXELS, DATAPIN, CLOCKPIN, DOTSTAR_BRG);

// IMPORTANT: To reduce NeoPixel burnout risk, add 1000 uF capacitor across
// pixel power leads, add 300 - 500 Ohm resistor on first pixel's data input
// and minimize distance between Arduino and first pixel.  Avoid connecting
// on a live circuit...if you must, connect GND first.


// A 'magic word' precedes each block of LED data; this assists the
// microcontroller in syncing up with the host-side software and latching
// frames at the correct time.  You may see an initial glitchy frame or
// two until the two come into alignment.  Immediately following the
// magic word are three bytes: a 16-bit count of the number of LEDs (high
// byte first) followed by a simple checksum value (high byte XOR low byte
// XOR 0x55).  LED data follows, 3 bytes per LED, in order R, G, B, where
// 0 = off and 255 = max brightness.  LPD8806 pixels only have 7-bit
// brightness control, so each value is divided by two; the 8-bit format
// is used to maintain compatibility with the protocol set forth by the
// WS2801 streaming code (those LEDs use 8-bit values).
static const uint8_t magic[] = { 'A','d','a' };
#define MAGICSIZE  sizeof(magic)
#define HEADERSIZE (MAGICSIZE + 3)
static uint8_t
  buffer[HEADERSIZE], // Serial input buffer
  bytesBuffered = 0;  // Amount of data in buffer

// If no serial data is received for a while, the LEDs are shut off
// automatically.  This avoids the annoying "stuck pixel" look when
// quitting LED display programs on the host computer.
static const unsigned long serialTimeout = 15000; // 15 seconds
static unsigned long       lastByteTime, lastAckTime;



void setup() {
  // This is for Trinket 5V 16MHz, you can remove these three lines if you are not using a Trinket
  //#if defined (__AVR_ATtiny85__)
  //  if (F_CPU == 16000000) clock_prescale_set(clock_div_1);
  //#endif
  // End of trinket special code


 Serial.begin(115200); // 32u4 will ignore BPS and run full speed
 
 
  strip.begin();
  strip.show(); // Initialize all pixels to 'off'
  
 
  rainbowCycle(3); //test

  clearStrip();
  
  
  Serial.print("Ack\n");                 // Send ACK string to host
  lastByteTime = lastAckTime = millis(); // Initialize timers
}

void loop() {
   uint8_t       i, hi, lo, byteNum;
  int           c;
  long          nLEDs, remaining;
  unsigned long t;

Serial.print("start1");


 
  // HEADER-SEEKING BLOCK: locate 'magic word' at start of frame.

  // If any data in serial buffer, shift it down to starting position.
  for(i=0; i<bytesBuffered; i++)
    buffer[i] = buffer[HEADERSIZE - bytesBuffered + i];

  // Read bytes from serial input until there's a full header's worth.
  while(bytesBuffered < HEADERSIZE) {
    t = millis();
    if((c = Serial.read()) >= 0) {    // Data received?
      buffer[bytesBuffered++] = c;    // Store in buffer
      lastByteTime = lastAckTime = t; // Reset timeout counters
    } else {                          // No data, check for timeout...
      if(timeout(t, 10000) == true) return; // Start over
    }
  }

  // Have a header's worth of data.  Check for 'magic word' match.
  for(i=0; i<MAGICSIZE; i++) {
    if(buffer[i] != magic[i]) {      // No match...
      if(i == 0) bytesBuffered -= 1; // resume search at next char
      else       bytesBuffered -= i; // resume at non-matching char
      return;
    }
  }


  // Magic word matches.  Now how about the checksum?
  hi = buffer[MAGICSIZE];
  lo = buffer[MAGICSIZE + 1];
  if(buffer[MAGICSIZE + 2] != (hi ^ lo ^ 0x55)) {
    bytesBuffered -= MAGICSIZE; // No match, resume after magic word
    return;
  }

   

  // Checksum appears valid.  Get 16-bit LED count, add 1 (nLEDs always > 0)
  nLEDs = remaining = 256L * (long)hi + (long)lo + 1L;
  bytesBuffered = 0; // Clear serial buffer
  byteNum = 0;
  
  int ledIndex = 0;

  //first two sets of 3 are the header, the next 25 sets of 3 are the LED data!

  
  remaining = 25;   //override ?  works with 5 !  //DEF NEEDS TO BE 25

  //seems to be plagued with the magic word after about 5 leds...
 Serial.println("start2");
  
   // DATA-FORWARDING BLOCK: move bytes from serial input to LED output.
  while(remaining > 0) { // While more LED data is expected...
    
     
    t = millis();
    if((c = Serial.read()) >= 0) {    // Successful read?

      
       /*
       Serial.print(ledIndex);
        Serial.print(" ");
         Serial.print(byteNum);
        Serial.print(" got ");
         Serial.println(c);
         */
         
//spot 1 is green
//spot 2 is blue

         //wants an unsigned int!!
        
      lastByteTime = lastAckTime = t; // Reset timeout counters
      buffer[byteNum++] = c;          // Store in data buffer
      if(byteNum == 3) {              // Have a full LED's worth?
 
       // uint32_t color = buffer[2] << 16 + buffer[1]<<8 + buffer[0];

        //r g b
        if(ledIndex < 20)  //quick fix to get rid of weird green and pink static leds..
       strip.setPixelColor(ledIndex+5, getColor(buffer[2],buffer[0],buffer[1])); //this is the correct color order
        
        // strip.setPixelColor(ledIndex, getColor(0xFF,0,0));
       
         byteNum = 0;
         
        ledIndex++;
        remaining--;  //this is borked?  27 or 30 ?
      }
    } else { // No data, check for timeout...
     
      
      if(timeout(t, nLEDs) == true) return; // Start over - if it cycles you know it timed out
    }


      strip.show();
      
  }


  
}

// Fill the dots one after the other with a color
void colorWipe(uint32_t c, uint8_t wait) {
  for(uint16_t i=0; i<strip.numPixels(); i++) {
    strip.setPixelColor(i, c);
    strip.show();
    delay(wait);
  }
}

void rainbow(uint8_t wait) {
  uint16_t i, j;

  for(j=0; j<256; j++) {
    for(i=0; i<strip.numPixels(); i++) {
      strip.setPixelColor(i, Wheel((i+j) & 255));
    }
    strip.show();
    delay(wait);
  }
}

// Slightly different, this makes the rainbow equally distributed throughout
void rainbowCycle(uint8_t wait) {
  uint16_t i, j;

  for(j=0; j<256*5; j++) { // 5 cycles of all colors on wheel
    for(i=0; i< strip.numPixels(); i++) {
      strip.setPixelColor(i, Wheel(((i * 256 / strip.numPixels()) + j) & 255));
    }
    strip.show();
    delay(wait);
  }
}

//Theatre-style crawling lights.
void theaterChase(uint32_t c, uint8_t wait) {
  for (int j=0; j<10; j++) {  //do 10 cycles of chasing
    for (int q=0; q < 3; q++) {
      for (int i=0; i < strip.numPixels(); i=i+3) {
        strip.setPixelColor(i+q, c);    //turn every third pixel on
      }
      strip.show();

      delay(wait);

      for (int i=0; i < strip.numPixels(); i=i+3) {
        strip.setPixelColor(i+q, 0);        //turn every third pixel off
      }
    }
  }
}

//Theatre-style crawling lights with rainbow effect
void theaterChaseRainbow(uint8_t wait) {
  for (int j=0; j < 256; j++) {     // cycle all 256 colors in the wheel
    for (int q=0; q < 3; q++) {
      for (int i=0; i < strip.numPixels(); i=i+3) {
        strip.setPixelColor(i+q, Wheel( (i+j) % 255));    //turn every third pixel on
      }
      strip.show();

      delay(wait);

      for (int i=0; i < strip.numPixels(); i=i+3) {
        strip.setPixelColor(i+q, 0);        //turn every third pixel off
      }
    }
  }
}

// Input a value 0 to 255 to get a color value.
// The colours are a transition r - g - b - back to r.
uint32_t Wheel(byte WheelPos) {
  WheelPos = 255 - WheelPos;
  if(WheelPos < 85) {
    return strip.Color(255 - WheelPos * 3, 0, WheelPos * 3);
  }
  if(WheelPos < 170) {
    WheelPos -= 85;
    return strip.Color(0, WheelPos * 3, 255 - WheelPos * 3);
  }
  WheelPos -= 170;
  return strip.Color(WheelPos * 3, 255 - WheelPos * 3, 0);
}

// Function is called when no pending serial data is available.
static boolean timeout(
  unsigned long t,       // Current time, milliseconds
  int           nLEDs) { // Number of LEDs
  // If condition persists, send an ACK packet to host once every
  // second to alert it to our presence.
  if((t - lastAckTime) > 1000) {
    Serial.print("Ada\n"); // Send ACK string to host
    lastAckTime = t;       // Reset counter
  }
  // If no data received for an extended time, turn off all LEDs.
  if((t - lastByteTime) > serialTimeout) {
    long bytes = nLEDs * 3L;
    //latch(nLEDs);      // Latch any partial/incomplete data in strand
    while(bytes--) {   // Issue all new data to turn off strand
     // while(!(SPSR & _BV(SPIF))); // Wait for prior byte out
      //SPDR = 0x80;                // Issue next byte (0x80 = LED off)
    }
   // latch(nLEDs);      // Latch 'all off' data
    lastByteTime  = t; // Reset counter
    bytesBuffered = 0; // Clear serial buffer
    return true;
  }
  return false; // No timeout
}


 void clearStrip()
{
  int i =0;
    for(i=0; i< strip.numPixels(); i++) {
      strip.setPixelColor(i, 0);
    }
    strip.show();
  
 }


static uint32_t getColor(byte r, byte g, byte b)
{

  
  uint32_t c;
  c = r;
  c <<= 8;
  c |= g;
  c <<= 8;
  c |= b;
  return c;

  
  }
