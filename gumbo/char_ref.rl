// Copyright 2011 Google Inc. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Author: jdtang@google.com (Jonathan Tang)
//
// This is a Ragel state machine re-implementation of the original char_ref.c,
// rewritten to improve efficiency.  To generate the .c file from it,
//
// $ ragel -F0 char_ref.rl
//
// The generated source is also checked into source control so that most people
// hacking on the parser do not need to install ragel.

#include "char_ref.h"

#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>     // Only for debug assertions at present.

#include "error.h"
#include "string_piece.h"
#include "utf8.h"
#include "util.h"

struct GumboInternalParser;

const int kGumboNoChar = -1;

// Table of replacement characters.  The spec specifies that any occurrence of
// the first character should be replaced by the second character, and a parse
// error recorded.
typedef struct {
  int from_char;
  int to_char;
} CharReplacement;

static const CharReplacement kCharReplacements[] = {
  { 0x00, 0xfffd },
  { 0x0d, 0x000d },
  { 0x80, 0x20ac },
  { 0x81, 0x0081 },
  { 0x82, 0x201A },
  { 0x83, 0x0192 },
  { 0x84, 0x201E },
  { 0x85, 0x2026 },
  { 0x86, 0x2020 },
  { 0x87, 0x2021 },
  { 0x88, 0x02C6 },
  { 0x89, 0x2030 },
  { 0x8A, 0x0160 },
  { 0x8B, 0x2039 },
  { 0x8C, 0x0152 },
  { 0x8D, 0x008D },
  { 0x8E, 0x017D },
  { 0x8F, 0x008F },
  { 0x90, 0x0090 },
  { 0x91, 0x2018 },
  { 0x92, 0x2019 },
  { 0x93, 0x201C },
  { 0x94, 0x201D },
  { 0x95, 0x2022 },
  { 0x96, 0x2013 },
  { 0x97, 0x2014 },
  { 0x98, 0x02DC },
  { 0x99, 0x2122 },
  { 0x9A, 0x0161 },
  { 0x9B, 0x203A },
  { 0x9C, 0x0153 },
  { 0x9D, 0x009D },
  { 0x9E, 0x017E },
  { 0x9F, 0x0178 },
  // Terminator.
  { -1, -1 }
};

static int parse_digit(int c, bool allow_hex) {
  if (c >= '0' && c <= '9') {
    return c - '0';
  }
  if (allow_hex && c >= 'a' && c <= 'f') {
    return c - 'a' + 10;
  }
  if (allow_hex && c >= 'A' && c <= 'F') {
    return c - 'A' + 10;
  }
  return -1;
}

static void add_no_digit_error(
    struct GumboInternalParser* parser, Utf8Iterator* input) {
  GumboError* error = gumbo_add_error(parser);
  if (!error) {
    return;
  }
  utf8iterator_fill_error_at_mark(input, error);
  error->type = GUMBO_ERR_NUMERIC_CHAR_REF_NO_DIGITS;
}

static void add_codepoint_error(
    struct GumboInternalParser* parser, Utf8Iterator* input,
    GumboErrorType type, int codepoint) {
  GumboError* error = gumbo_add_error(parser);
  if (!error) {
    return;
  }
  utf8iterator_fill_error_at_mark(input, error);
  error->type = type;
  error->v.codepoint = codepoint;
}

static void add_named_reference_error(
    struct GumboInternalParser* parser, Utf8Iterator* input,
    GumboErrorType type, GumboStringPiece text) {
  GumboError* error = gumbo_add_error(parser);
  if (!error) {
    return;
  }
  utf8iterator_fill_error_at_mark(input, error);
  error->type = type;
  error->v.text = text;
}

static int maybe_replace_codepoint(int codepoint) {
  for (int i = 0; kCharReplacements[i].from_char != -1; ++i) {
    if (kCharReplacements[i].from_char == codepoint) {
      return kCharReplacements[i].to_char;
    }
  }
  return -1;
}

static bool consume_numeric_ref(
    struct GumboInternalParser* parser, Utf8Iterator* input, int* output) {
  utf8iterator_next(input);
  bool is_hex = false;
  int c = utf8iterator_current(input);
  if (c == 'x' || c == 'X') {
    is_hex = true;
    utf8iterator_next(input);
    c = utf8iterator_current(input);
  }

  int digit = parse_digit(c, is_hex);
  if (digit == -1) {
    // First digit was invalid; add a parse error and return.
    add_no_digit_error(parser, input);
    utf8iterator_reset(input);
    *output = kGumboNoChar;
    return false;
  }

  int codepoint = 0;
  bool status = true;
  do {
    if (codepoint <= 0x10ffff) codepoint = (codepoint * (is_hex ? 16 : 10)) + digit;
    utf8iterator_next(input);
    digit = parse_digit(utf8iterator_current(input), is_hex);
  } while (digit != -1);

  if (utf8iterator_current(input) != ';') {
    add_codepoint_error(
        parser, input, GUMBO_ERR_NUMERIC_CHAR_REF_WITHOUT_SEMICOLON, codepoint);
    status = false;
  } else {
    utf8iterator_next(input);
  }

  int replacement = maybe_replace_codepoint(codepoint);
  if (replacement != -1) {
    add_codepoint_error(
        parser, input, GUMBO_ERR_NUMERIC_CHAR_REF_INVALID, codepoint);
    *output = replacement;
    return false;
  }

  if ((codepoint >= 0xd800 && codepoint <= 0xdfff) || codepoint > 0x10ffff) {
    add_codepoint_error(
        parser, input, GUMBO_ERR_NUMERIC_CHAR_REF_INVALID, codepoint);
    *output = 0xfffd;
    return false;
  }

  if (utf8_is_invalid_code_point(codepoint) || codepoint == 0xb) {
    add_codepoint_error(
        parser, input, GUMBO_ERR_NUMERIC_CHAR_REF_INVALID, codepoint);
    status = false;
    // But return it anyway, per spec.
  }
  *output = codepoint;
  return status;
}

static bool maybe_add_invalid_named_reference(
    struct GumboInternalParser* parser, Utf8Iterator* input) {
  // The iterator will always be reset in this code path, so we don't need to
  // worry about consuming characters.
  const char* start = utf8iterator_get_char_pointer(input);
  int c = utf8iterator_current(input);
  while ((c >= 'a' && c <= 'z') ||
         (c >= 'A' && c <= 'Z') ||
         (c >= '0' && c <= '9')) {
    utf8iterator_next(input);
    c = utf8iterator_current(input);
  }
  if (c == ';') {
    GumboStringPiece bad_ref;
    bad_ref.data = start;
    bad_ref.length = utf8iterator_get_char_pointer(input) - start;
    add_named_reference_error(
        parser, input, GUMBO_ERR_NAMED_CHAR_REF_INVALID, bad_ref);
    return false;
  }
  return true;
}

%%{
machine char_ref;

valid_named_ref := |*
  'AElig;' => { output->first = 0xc6; fbreak; };
  'AElig' => { output->first = 0xc6; fbreak; };
  'AMP;' => { output->first = 0x26; fbreak; };
  'AMP' => { output->first = 0x26; fbreak; };
  'Aacute;' => { output->first = 0xc1; fbreak; };
  'Aacute' => { output->first = 0xc1; fbreak; };
  'Abreve;' => { output->first = 0x0102; fbreak; };
  'Acirc;' => { output->first = 0xc2; fbreak; };
  'Acirc' => { output->first = 0xc2; fbreak; };
  'Acy;' => { output->first = 0x0410; fbreak; };
  'Afr;' => { output->first = 0x0001d504; fbreak; };
  'Agrave;' => { output->first = 0xc0; fbreak; };
  'Agrave' => { output->first = 0xc0; fbreak; };
  'Alpha;' => { output->first = 0x0391; fbreak; };
  'Amacr;' => { output->first = 0x0100; fbreak; };
  'And;' => { output->first = 0x2a53; fbreak; };
  'Aogon;' => { output->first = 0x0104; fbreak; };
  'Aopf;' => { output->first = 0x0001d538; fbreak; };
  'ApplyFunction;' => { output->first = 0x2061; fbreak; };
  'Aring;' => { output->first = 0xc5; fbreak; };
  'Aring' => { output->first = 0xc5; fbreak; };
  'Ascr;' => { output->first = 0x0001d49c; fbreak; };
  'Assign;' => { output->first = 0x2254; fbreak; };
  'Atilde;' => { output->first = 0xc3; fbreak; };
  'Atilde' => { output->first = 0xc3; fbreak; };
  'Auml;' => { output->first = 0xc4; fbreak; };
  'Auml' => { output->first = 0xc4; fbreak; };
  'Backslash;' => { output->first = 0x2216; fbreak; };
  'Barv;' => { output->first = 0x2ae7; fbreak; };
  'Barwed;' => { output->first = 0x2306; fbreak; };
  'Bcy;' => { output->first = 0x0411; fbreak; };
  'Because;' => { output->first = 0x2235; fbreak; };
  'Bernoullis;' => { output->first = 0x212c; fbreak; };
  'Beta;' => { output->first = 0x0392; fbreak; };
  'Bfr;' => { output->first = 0x0001d505; fbreak; };
  'Bopf;' => { output->first = 0x0001d539; fbreak; };
  'Breve;' => { output->first = 0x02d8; fbreak; };
  'Bscr;' => { output->first = 0x212c; fbreak; };
  'Bumpeq;' => { output->first = 0x224e; fbreak; };
  'CHcy;' => { output->first = 0x0427; fbreak; };
  'COPY;' => { output->first = 0xa9; fbreak; };
  'COPY' => { output->first = 0xa9; fbreak; };
  'Cacute;' => { output->first = 0x0106; fbreak; };
  'Cap;' => { output->first = 0x22d2; fbreak; };
  'CapitalDifferentialD;' => { output->first = 0x2145; fbreak; };
  'Cayleys;' => { output->first = 0x212d; fbreak; };
  'Ccaron;' => { output->first = 0x010c; fbreak; };
  'Ccedil;' => { output->first = 0xc7; fbreak; };
  'Ccedil' => { output->first = 0xc7; fbreak; };
  'Ccirc;' => { output->first = 0x0108; fbreak; };
  'Cconint;' => { output->first = 0x2230; fbreak; };
  'Cdot;' => { output->first = 0x010a; fbreak; };
  'Cedilla;' => { output->first = 0xb8; fbreak; };
  'CenterDot;' => { output->first = 0xb7; fbreak; };
  'Cfr;' => { output->first = 0x212d; fbreak; };
  'Chi;' => { output->first = 0x03a7; fbreak; };
  'CircleDot;' => { output->first = 0x2299; fbreak; };
  'CircleMinus;' => { output->first = 0x2296; fbreak; };
  'CirclePlus;' => { output->first = 0x2295; fbreak; };
  'CircleTimes;' => { output->first = 0x2297; fbreak; };
  'ClockwiseContourIntegral;' => { output->first = 0x2232; fbreak; };
  'CloseCurlyDoubleQuote;' => { output->first = 0x201d; fbreak; };
  'CloseCurlyQuote;' => { output->first = 0x2019; fbreak; };
  'Colon;' => { output->first = 0x2237; fbreak; };
  'Colone;' => { output->first = 0x2a74; fbreak; };
  'Congruent;' => { output->first = 0x2261; fbreak; };
  'Conint;' => { output->first = 0x222f; fbreak; };
  'ContourIntegral;' => { output->first = 0x222e; fbreak; };
  'Copf;' => { output->first = 0x2102; fbreak; };
  'Coproduct;' => { output->first = 0x2210; fbreak; };
  'CounterClockwiseContourIntegral;' => { output->first = 0x2233; fbreak; };
  'Cross;' => { output->first = 0x2a2f; fbreak; };
  'Cscr;' => { output->first = 0x0001d49e; fbreak; };
  'Cup;' => { output->first = 0x22d3; fbreak; };
  'CupCap;' => { output->first = 0x224d; fbreak; };
  'DD;' => { output->first = 0x2145; fbreak; };
  'DDotrahd;' => { output->first = 0x2911; fbreak; };
  'DJcy;' => { output->first = 0x0402; fbreak; };
  'DScy;' => { output->first = 0x0405; fbreak; };
  'DZcy;' => { output->first = 0x040f; fbreak; };
  'Dagger;' => { output->first = 0x2021; fbreak; };
  'Darr;' => { output->first = 0x21a1; fbreak; };
  'Dashv;' => { output->first = 0x2ae4; fbreak; };
  'Dcaron;' => { output->first = 0x010e; fbreak; };
  'Dcy;' => { output->first = 0x0414; fbreak; };
  'Del;' => { output->first = 0x2207; fbreak; };
  'Delta;' => { output->first = 0x0394; fbreak; };
  'Dfr;' => { output->first = 0x0001d507; fbreak; };
  'DiacriticalAcute;' => { output->first = 0xb4; fbreak; };
  'DiacriticalDot;' => { output->first = 0x02d9; fbreak; };
  'DiacriticalDoubleAcute;' => { output->first = 0x02dd; fbreak; };
  'DiacriticalGrave;' => { output->first = 0x60; fbreak; };
  'DiacriticalTilde;' => { output->first = 0x02dc; fbreak; };
  'Diamond;' => { output->first = 0x22c4; fbreak; };
  'DifferentialD;' => { output->first = 0x2146; fbreak; };
  'Dopf;' => { output->first = 0x0001d53b; fbreak; };
  'Dot;' => { output->first = 0xa8; fbreak; };
  'DotDot;' => { output->first = 0x20dc; fbreak; };
  'DotEqual;' => { output->first = 0x2250; fbreak; };
  'DoubleContourIntegral;' => { output->first = 0x222f; fbreak; };
  'DoubleDot;' => { output->first = 0xa8; fbreak; };
  'DoubleDownArrow;' => { output->first = 0x21d3; fbreak; };
  'DoubleLeftArrow;' => { output->first = 0x21d0; fbreak; };
  'DoubleLeftRightArrow;' => { output->first = 0x21d4; fbreak; };
  'DoubleLeftTee;' => { output->first = 0x2ae4; fbreak; };
  'DoubleLongLeftArrow;' => { output->first = 0x27f8; fbreak; };
  'DoubleLongLeftRightArrow;' => { output->first = 0x27fa; fbreak; };
  'DoubleLongRightArrow;' => { output->first = 0x27f9; fbreak; };
  'DoubleRightArrow;' => { output->first = 0x21d2; fbreak; };
  'DoubleRightTee;' => { output->first = 0x22a8; fbreak; };
  'DoubleUpArrow;' => { output->first = 0x21d1; fbreak; };
  'DoubleUpDownArrow;' => { output->first = 0x21d5; fbreak; };
  'DoubleVerticalBar;' => { output->first = 0x2225; fbreak; };
  'DownArrow;' => { output->first = 0x2193; fbreak; };
  'DownArrowBar;' => { output->first = 0x2913; fbreak; };
  'DownArrowUpArrow;' => { output->first = 0x21f5; fbreak; };
  'DownBreve;' => { output->first = 0x0311; fbreak; };
  'DownLeftRightVector;' => { output->first = 0x2950; fbreak; };
  'DownLeftTeeVector;' => { output->first = 0x295e; fbreak; };
  'DownLeftVector;' => { output->first = 0x21bd; fbreak; };
  'DownLeftVectorBar;' => { output->first = 0x2956; fbreak; };
  'DownRightTeeVector;' => { output->first = 0x295f; fbreak; };
  'DownRightVector;' => { output->first = 0x21c1; fbreak; };
  'DownRightVectorBar;' => { output->first = 0x2957; fbreak; };
  'DownTee;' => { output->first = 0x22a4; fbreak; };
  'DownTeeArrow;' => { output->first = 0x21a7; fbreak; };
  'Downarrow;' => { output->first = 0x21d3; fbreak; };
  'Dscr;' => { output->first = 0x0001d49f; fbreak; };
  'Dstrok;' => { output->first = 0x0110; fbreak; };
  'ENG;' => { output->first = 0x014a; fbreak; };
  'ETH;' => { output->first = 0xd0; fbreak; };
  'ETH' => { output->first = 0xd0; fbreak; };
  'Eacute;' => { output->first = 0xc9; fbreak; };
  'Eacute' => { output->first = 0xc9; fbreak; };
  'Ecaron;' => { output->first = 0x011a; fbreak; };
  'Ecirc;' => { output->first = 0xca; fbreak; };
  'Ecirc' => { output->first = 0xca; fbreak; };
  'Ecy;' => { output->first = 0x042d; fbreak; };
  'Edot;' => { output->first = 0x0116; fbreak; };
  'Efr;' => { output->first = 0x0001d508; fbreak; };
  'Egrave;' => { output->first = 0xc8; fbreak; };
  'Egrave' => { output->first = 0xc8; fbreak; };
  'Element;' => { output->first = 0x2208; fbreak; };
  'Emacr;' => { output->first = 0x0112; fbreak; };
  'EmptySmallSquare;' => { output->first = 0x25fb; fbreak; };
  'EmptyVerySmallSquare;' => { output->first = 0x25ab; fbreak; };
  'Eogon;' => { output->first = 0x0118; fbreak; };
  'Eopf;' => { output->first = 0x0001d53c; fbreak; };
  'Epsilon;' => { output->first = 0x0395; fbreak; };
  'Equal;' => { output->first = 0x2a75; fbreak; };
  'EqualTilde;' => { output->first = 0x2242; fbreak; };
  'Equilibrium;' => { output->first = 0x21cc; fbreak; };
  'Escr;' => { output->first = 0x2130; fbreak; };
  'Esim;' => { output->first = 0x2a73; fbreak; };
  'Eta;' => { output->first = 0x0397; fbreak; };
  'Euml;' => { output->first = 0xcb; fbreak; };
  'Euml' => { output->first = 0xcb; fbreak; };
  'Exists;' => { output->first = 0x2203; fbreak; };
  'ExponentialE;' => { output->first = 0x2147; fbreak; };
  'Fcy;' => { output->first = 0x0424; fbreak; };
  'Ffr;' => { output->first = 0x0001d509; fbreak; };
  'FilledSmallSquare;' => { output->first = 0x25fc; fbreak; };
  'FilledVerySmallSquare;' => { output->first = 0x25aa; fbreak; };
  'Fopf;' => { output->first = 0x0001d53d; fbreak; };
  'ForAll;' => { output->first = 0x2200; fbreak; };
  'Fouriertrf;' => { output->first = 0x2131; fbreak; };
  'Fscr;' => { output->first = 0x2131; fbreak; };
  'GJcy;' => { output->first = 0x0403; fbreak; };
  'GT;' => { output->first = 0x3e; fbreak; };
  'GT' => { output->first = 0x3e; fbreak; };
  'Gamma;' => { output->first = 0x0393; fbreak; };
  'Gammad;' => { output->first = 0x03dc; fbreak; };
  'Gbreve;' => { output->first = 0x011e; fbreak; };
  'Gcedil;' => { output->first = 0x0122; fbreak; };
  'Gcirc;' => { output->first = 0x011c; fbreak; };
  'Gcy;' => { output->first = 0x0413; fbreak; };
  'Gdot;' => { output->first = 0x0120; fbreak; };
  'Gfr;' => { output->first = 0x0001d50a; fbreak; };
  'Gg;' => { output->first = 0x22d9; fbreak; };
  'Gopf;' => { output->first = 0x0001d53e; fbreak; };
  'GreaterEqual;' => { output->first = 0x2265; fbreak; };
  'GreaterEqualLess;' => { output->first = 0x22db; fbreak; };
  'GreaterFullEqual;' => { output->first = 0x2267; fbreak; };
  'GreaterGreater;' => { output->first = 0x2aa2; fbreak; };
  'GreaterLess;' => { output->first = 0x2277; fbreak; };
  'GreaterSlantEqual;' => { output->first = 0x2a7e; fbreak; };
  'GreaterTilde;' => { output->first = 0x2273; fbreak; };
  'Gscr;' => { output->first = 0x0001d4a2; fbreak; };
  'Gt;' => { output->first = 0x226b; fbreak; };
  'HARDcy;' => { output->first = 0x042a; fbreak; };
  'Hacek;' => { output->first = 0x02c7; fbreak; };
  'Hat;' => { output->first = 0x5e; fbreak; };
  'Hcirc;' => { output->first = 0x0124; fbreak; };
  'Hfr;' => { output->first = 0x210c; fbreak; };
  'HilbertSpace;' => { output->first = 0x210b; fbreak; };
  'Hopf;' => { output->first = 0x210d; fbreak; };
  'HorizontalLine;' => { output->first = 0x2500; fbreak; };
  'Hscr;' => { output->first = 0x210b; fbreak; };
  'Hstrok;' => { output->first = 0x0126; fbreak; };
  'HumpDownHump;' => { output->first = 0x224e; fbreak; };
  'HumpEqual;' => { output->first = 0x224f; fbreak; };
  'IEcy;' => { output->first = 0x0415; fbreak; };
  'IJlig;' => { output->first = 0x0132; fbreak; };
  'IOcy;' => { output->first = 0x0401; fbreak; };
  'Iacute;' => { output->first = 0xcd; fbreak; };
  'Iacute' => { output->first = 0xcd; fbreak; };
  'Icirc;' => { output->first = 0xce; fbreak; };
  'Icirc' => { output->first = 0xce; fbreak; };
  'Icy;' => { output->first = 0x0418; fbreak; };
  'Idot;' => { output->first = 0x0130; fbreak; };
  'Ifr;' => { output->first = 0x2111; fbreak; };
  'Igrave;' => { output->first = 0xcc; fbreak; };
  'Igrave' => { output->first = 0xcc; fbreak; };
  'Im;' => { output->first = 0x2111; fbreak; };
  'Imacr;' => { output->first = 0x012a; fbreak; };
  'ImaginaryI;' => { output->first = 0x2148; fbreak; };
  'Implies;' => { output->first = 0x21d2; fbreak; };
  'Int;' => { output->first = 0x222c; fbreak; };
  'Integral;' => { output->first = 0x222b; fbreak; };
  'Intersection;' => { output->first = 0x22c2; fbreak; };
  'InvisibleComma;' => { output->first = 0x2063; fbreak; };
  'InvisibleTimes;' => { output->first = 0x2062; fbreak; };
  'Iogon;' => { output->first = 0x012e; fbreak; };
  'Iopf;' => { output->first = 0x0001d540; fbreak; };
  'Iota;' => { output->first = 0x0399; fbreak; };
  'Iscr;' => { output->first = 0x2110; fbreak; };
  'Itilde;' => { output->first = 0x0128; fbreak; };
  'Iukcy;' => { output->first = 0x0406; fbreak; };
  'Iuml;' => { output->first = 0xcf; fbreak; };
  'Iuml' => { output->first = 0xcf; fbreak; };
  'Jcirc;' => { output->first = 0x0134; fbreak; };
  'Jcy;' => { output->first = 0x0419; fbreak; };
  'Jfr;' => { output->first = 0x0001d50d; fbreak; };
  'Jopf;' => { output->first = 0x0001d541; fbreak; };
  'Jscr;' => { output->first = 0x0001d4a5; fbreak; };
  'Jsercy;' => { output->first = 0x0408; fbreak; };
  'Jukcy;' => { output->first = 0x0404; fbreak; };
  'KHcy;' => { output->first = 0x0425; fbreak; };
  'KJcy;' => { output->first = 0x040c; fbreak; };
  'Kappa;' => { output->first = 0x039a; fbreak; };
  'Kcedil;' => { output->first = 0x0136; fbreak; };
  'Kcy;' => { output->first = 0x041a; fbreak; };
  'Kfr;' => { output->first = 0x0001d50e; fbreak; };
  'Kopf;' => { output->first = 0x0001d542; fbreak; };
  'Kscr;' => { output->first = 0x0001d4a6; fbreak; };
  'LJcy;' => { output->first = 0x0409; fbreak; };
  'LT;' => { output->first = 0x3c; fbreak; };
  'LT' => { output->first = 0x3c; fbreak; };
  'Lacute;' => { output->first = 0x0139; fbreak; };
  'Lambda;' => { output->first = 0x039b; fbreak; };
  'Lang;' => { output->first = 0x27ea; fbreak; };
  'Laplacetrf;' => { output->first = 0x2112; fbreak; };
  'Larr;' => { output->first = 0x219e; fbreak; };
  'Lcaron;' => { output->first = 0x013d; fbreak; };
  'Lcedil;' => { output->first = 0x013b; fbreak; };
  'Lcy;' => { output->first = 0x041b; fbreak; };
  'LeftAngleBracket;' => { output->first = 0x27e8; fbreak; };
  'LeftArrow;' => { output->first = 0x2190; fbreak; };
  'LeftArrowBar;' => { output->first = 0x21e4; fbreak; };
  'LeftArrowRightArrow;' => { output->first = 0x21c6; fbreak; };
  'LeftCeiling;' => { output->first = 0x2308; fbreak; };
  'LeftDoubleBracket;' => { output->first = 0x27e6; fbreak; };
  'LeftDownTeeVector;' => { output->first = 0x2961; fbreak; };
  'LeftDownVector;' => { output->first = 0x21c3; fbreak; };
  'LeftDownVectorBar;' => { output->first = 0x2959; fbreak; };
  'LeftFloor;' => { output->first = 0x230a; fbreak; };
  'LeftRightArrow;' => { output->first = 0x2194; fbreak; };
  'LeftRightVector;' => { output->first = 0x294e; fbreak; };
  'LeftTee;' => { output->first = 0x22a3; fbreak; };
  'LeftTeeArrow;' => { output->first = 0x21a4; fbreak; };
  'LeftTeeVector;' => { output->first = 0x295a; fbreak; };
  'LeftTriangle;' => { output->first = 0x22b2; fbreak; };
  'LeftTriangleBar;' => { output->first = 0x29cf; fbreak; };
  'LeftTriangleEqual;' => { output->first = 0x22b4; fbreak; };
  'LeftUpDownVector;' => { output->first = 0x2951; fbreak; };
  'LeftUpTeeVector;' => { output->first = 0x2960; fbreak; };
  'LeftUpVector;' => { output->first = 0x21bf; fbreak; };
  'LeftUpVectorBar;' => { output->first = 0x2958; fbreak; };
  'LeftVector;' => { output->first = 0x21bc; fbreak; };
  'LeftVectorBar;' => { output->first = 0x2952; fbreak; };
  'Leftarrow;' => { output->first = 0x21d0; fbreak; };
  'Leftrightarrow;' => { output->first = 0x21d4; fbreak; };
  'LessEqualGreater;' => { output->first = 0x22da; fbreak; };
  'LessFullEqual;' => { output->first = 0x2266; fbreak; };
  'LessGreater;' => { output->first = 0x2276; fbreak; };
  'LessLess;' => { output->first = 0x2aa1; fbreak; };
  'LessSlantEqual;' => { output->first = 0x2a7d; fbreak; };
  'LessTilde;' => { output->first = 0x2272; fbreak; };
  'Lfr;' => { output->first = 0x0001d50f; fbreak; };
  'Ll;' => { output->first = 0x22d8; fbreak; };
  'Lleftarrow;' => { output->first = 0x21da; fbreak; };
  'Lmidot;' => { output->first = 0x013f; fbreak; };
  'LongLeftArrow;' => { output->first = 0x27f5; fbreak; };
  'LongLeftRightArrow;' => { output->first = 0x27f7; fbreak; };
  'LongRightArrow;' => { output->first = 0x27f6; fbreak; };
  'Longleftarrow;' => { output->first = 0x27f8; fbreak; };
  'Longleftrightarrow;' => { output->first = 0x27fa; fbreak; };
  'Longrightarrow;' => { output->first = 0x27f9; fbreak; };
  'Lopf;' => { output->first = 0x0001d543; fbreak; };
  'LowerLeftArrow;' => { output->first = 0x2199; fbreak; };
  'LowerRightArrow;' => { output->first = 0x2198; fbreak; };
  'Lscr;' => { output->first = 0x2112; fbreak; };
  'Lsh;' => { output->first = 0x21b0; fbreak; };
  'Lstrok;' => { output->first = 0x0141; fbreak; };
  'Lt;' => { output->first = 0x226a; fbreak; };
  'Map;' => { output->first = 0x2905; fbreak; };
  'Mcy;' => { output->first = 0x041c; fbreak; };
  'MediumSpace;' => { output->first = 0x205f; fbreak; };
  'Mellintrf;' => { output->first = 0x2133; fbreak; };
  'Mfr;' => { output->first = 0x0001d510; fbreak; };
  'MinusPlus;' => { output->first = 0x2213; fbreak; };
  'Mopf;' => { output->first = 0x0001d544; fbreak; };
  'Mscr;' => { output->first = 0x2133; fbreak; };
  'Mu;' => { output->first = 0x039c; fbreak; };
  'NJcy;' => { output->first = 0x040a; fbreak; };
  'Nacute;' => { output->first = 0x0143; fbreak; };
  'Ncaron;' => { output->first = 0x0147; fbreak; };
  'Ncedil;' => { output->first = 0x0145; fbreak; };
  'Ncy;' => { output->first = 0x041d; fbreak; };
  'NegativeMediumSpace;' => { output->first = 0x200b; fbreak; };
  'NegativeThickSpace;' => { output->first = 0x200b; fbreak; };
  'NegativeThinSpace;' => { output->first = 0x200b; fbreak; };
  'NegativeVeryThinSpace;' => { output->first = 0x200b; fbreak; };
  'NestedGreaterGreater;' => { output->first = 0x226b; fbreak; };
  'NestedLessLess;' => { output->first = 0x226a; fbreak; };
  'NewLine;' => { output->first = 0x0a; fbreak; };
  'Nfr;' => { output->first = 0x0001d511; fbreak; };
  'NoBreak;' => { output->first = 0x2060; fbreak; };
  'NonBreakingSpace;' => { output->first = 0xa0; fbreak; };
  'Nopf;' => { output->first = 0x2115; fbreak; };
  'Not;' => { output->first = 0x2aec; fbreak; };
  'NotCongruent;' => { output->first = 0x2262; fbreak; };
  'NotCupCap;' => { output->first = 0x226d; fbreak; };
  'NotDoubleVerticalBar;' => { output->first = 0x2226; fbreak; };
  'NotElement;' => { output->first = 0x2209; fbreak; };
  'NotEqual;' => { output->first = 0x2260; fbreak; };
  'NotEqualTilde;' => { output->first = 0x2242; output->second = 0x0338; fbreak; };
  'NotExists;' => { output->first = 0x2204; fbreak; };
  'NotGreater;' => { output->first = 0x226f; fbreak; };
  'NotGreaterEqual;' => { output->first = 0x2271; fbreak; };
  'NotGreaterFullEqual;' => { output->first = 0x2267; output->second = 0x0338; fbreak; };
  'NotGreaterGreater;' => { output->first = 0x226b; output->second = 0x0338; fbreak; };
  'NotGreaterLess;' => { output->first = 0x2279; fbreak; };
  'NotGreaterSlantEqual;' => { output->first = 0x2a7e; output->second = 0x0338; fbreak; };
  'NotGreaterTilde;' => { output->first = 0x2275; fbreak; };
  'NotHumpDownHump;' => { output->first = 0x224e; output->second = 0x0338; fbreak; };
  'NotHumpEqual;' => { output->first = 0x224f; output->second = 0x0338; fbreak; };
  'NotLeftTriangle;' => { output->first = 0x22ea; fbreak; };
  'NotLeftTriangleBar;' => { output->first = 0x29cf; output->second = 0x0338; fbreak; };
  'NotLeftTriangleEqual;' => { output->first = 0x22ec; fbreak; };
  'NotLess;' => { output->first = 0x226e; fbreak; };
  'NotLessEqual;' => { output->first = 0x2270; fbreak; };
  'NotLessGreater;' => { output->first = 0x2278; fbreak; };
  'NotLessLess;' => { output->first = 0x226a; output->second = 0x0338; fbreak; };
  'NotLessSlantEqual;' => { output->first = 0x2a7d; output->second = 0x0338; fbreak; };
  'NotLessTilde;' => { output->first = 0x2274; fbreak; };
  'NotNestedGreaterGreater;' => { output->first = 0x2aa2; output->second = 0x0338; fbreak; };
  'NotNestedLessLess;' => { output->first = 0x2aa1; output->second = 0x0338; fbreak; };
  'NotPrecedes;' => { output->first = 0x2280; fbreak; };
  'NotPrecedesEqual;' => { output->first = 0x2aaf; output->second = 0x0338; fbreak; };
  'NotPrecedesSlantEqual;' => { output->first = 0x22e0; fbreak; };
  'NotReverseElement;' => { output->first = 0x220c; fbreak; };
  'NotRightTriangle;' => { output->first = 0x22eb; fbreak; };
  'NotRightTriangleBar;' => { output->first = 0x29d0; output->second = 0x0338; fbreak; };
  'NotRightTriangleEqual;' => { output->first = 0x22ed; fbreak; };
  'NotSquareSubset;' => { output->first = 0x228f; output->second = 0x0338; fbreak; };
  'NotSquareSubsetEqual;' => { output->first = 0x22e2; fbreak; };
  'NotSquareSuperset;' => { output->first = 0x2290; output->second = 0x0338; fbreak; };
  'NotSquareSupersetEqual;' => { output->first = 0x22e3; fbreak; };
  'NotSubset;' => { output->first = 0x2282; output->second = 0x20d2; fbreak; };
  'NotSubsetEqual;' => { output->first = 0x2288; fbreak; };
  'NotSucceeds;' => { output->first = 0x2281; fbreak; };
  'NotSucceedsEqual;' => { output->first = 0x2ab0; output->second = 0x0338; fbreak; };
  'NotSucceedsSlantEqual;' => { output->first = 0x22e1; fbreak; };
  'NotSucceedsTilde;' => { output->first = 0x227f; output->second = 0x0338; fbreak; };
  'NotSuperset;' => { output->first = 0x2283; output->second = 0x20d2; fbreak; };
  'NotSupersetEqual;' => { output->first = 0x2289; fbreak; };
  'NotTilde;' => { output->first = 0x2241; fbreak; };
  'NotTildeEqual;' => { output->first = 0x2244; fbreak; };
  'NotTildeFullEqual;' => { output->first = 0x2247; fbreak; };
  'NotTildeTilde;' => { output->first = 0x2249; fbreak; };
  'NotVerticalBar;' => { output->first = 0x2224; fbreak; };
  'Nscr;' => { output->first = 0x0001d4a9; fbreak; };
  'Ntilde;' => { output->first = 0xd1; fbreak; };
  'Ntilde' => { output->first = 0xd1; fbreak; };
  'Nu;' => { output->first = 0x039d; fbreak; };
  'OElig;' => { output->first = 0x0152; fbreak; };
  'Oacute;' => { output->first = 0xd3; fbreak; };
  'Oacute' => { output->first = 0xd3; fbreak; };
  'Ocirc;' => { output->first = 0xd4; fbreak; };
  'Ocirc' => { output->first = 0xd4; fbreak; };
  'Ocy;' => { output->first = 0x041e; fbreak; };
  'Odblac;' => { output->first = 0x0150; fbreak; };
  'Ofr;' => { output->first = 0x0001d512; fbreak; };
  'Ograve;' => { output->first = 0xd2; fbreak; };
  'Ograve' => { output->first = 0xd2; fbreak; };
  'Omacr;' => { output->first = 0x014c; fbreak; };
  'Omega;' => { output->first = 0x03a9; fbreak; };
  'Omicron;' => { output->first = 0x039f; fbreak; };
  'Oopf;' => { output->first = 0x0001d546; fbreak; };
  'OpenCurlyDoubleQuote;' => { output->first = 0x201c; fbreak; };
  'OpenCurlyQuote;' => { output->first = 0x2018; fbreak; };
  'Or;' => { output->first = 0x2a54; fbreak; };
  'Oscr;' => { output->first = 0x0001d4aa; fbreak; };
  'Oslash;' => { output->first = 0xd8; fbreak; };
  'Oslash' => { output->first = 0xd8; fbreak; };
  'Otilde;' => { output->first = 0xd5; fbreak; };
  'Otilde' => { output->first = 0xd5; fbreak; };
  'Otimes;' => { output->first = 0x2a37; fbreak; };
  'Ouml;' => { output->first = 0xd6; fbreak; };
  'Ouml' => { output->first = 0xd6; fbreak; };
  'OverBar;' => { output->first = 0x203e; fbreak; };
  'OverBrace;' => { output->first = 0x23de; fbreak; };
  'OverBracket;' => { output->first = 0x23b4; fbreak; };
  'OverParenthesis;' => { output->first = 0x23dc; fbreak; };
  'PartialD;' => { output->first = 0x2202; fbreak; };
  'Pcy;' => { output->first = 0x041f; fbreak; };
  'Pfr;' => { output->first = 0x0001d513; fbreak; };
  'Phi;' => { output->first = 0x03a6; fbreak; };
  'Pi;' => { output->first = 0x03a0; fbreak; };
  'PlusMinus;' => { output->first = 0xb1; fbreak; };
  'Poincareplane;' => { output->first = 0x210c; fbreak; };
  'Popf;' => { output->first = 0x2119; fbreak; };
  'Pr;' => { output->first = 0x2abb; fbreak; };
  'Precedes;' => { output->first = 0x227a; fbreak; };
  'PrecedesEqual;' => { output->first = 0x2aaf; fbreak; };
  'PrecedesSlantEqual;' => { output->first = 0x227c; fbreak; };
  'PrecedesTilde;' => { output->first = 0x227e; fbreak; };
  'Prime;' => { output->first = 0x2033; fbreak; };
  'Product;' => { output->first = 0x220f; fbreak; };
  'Proportion;' => { output->first = 0x2237; fbreak; };
  'Proportional;' => { output->first = 0x221d; fbreak; };
  'Pscr;' => { output->first = 0x0001d4ab; fbreak; };
  'Psi;' => { output->first = 0x03a8; fbreak; };
  'QUOT;' => { output->first = 0x22; fbreak; };
  'QUOT' => { output->first = 0x22; fbreak; };
  'Qfr;' => { output->first = 0x0001d514; fbreak; };
  'Qopf;' => { output->first = 0x211a; fbreak; };
  'Qscr;' => { output->first = 0x0001d4ac; fbreak; };
  'RBarr;' => { output->first = 0x2910; fbreak; };
  'REG;' => { output->first = 0xae; fbreak; };
  'REG' => { output->first = 0xae; fbreak; };
  'Racute;' => { output->first = 0x0154; fbreak; };
  'Rang;' => { output->first = 0x27eb; fbreak; };
  'Rarr;' => { output->first = 0x21a0; fbreak; };
  'Rarrtl;' => { output->first = 0x2916; fbreak; };
  'Rcaron;' => { output->first = 0x0158; fbreak; };
  'Rcedil;' => { output->first = 0x0156; fbreak; };
  'Rcy;' => { output->first = 0x0420; fbreak; };
  'Re;' => { output->first = 0x211c; fbreak; };
  'ReverseElement;' => { output->first = 0x220b; fbreak; };
  'ReverseEquilibrium;' => { output->first = 0x21cb; fbreak; };
  'ReverseUpEquilibrium;' => { output->first = 0x296f; fbreak; };
  'Rfr;' => { output->first = 0x211c; fbreak; };
  'Rho;' => { output->first = 0x03a1; fbreak; };
  'RightAngleBracket;' => { output->first = 0x27e9; fbreak; };
  'RightArrow;' => { output->first = 0x2192; fbreak; };
  'RightArrowBar;' => { output->first = 0x21e5; fbreak; };
  'RightArrowLeftArrow;' => { output->first = 0x21c4; fbreak; };
  'RightCeiling;' => { output->first = 0x2309; fbreak; };
  'RightDoubleBracket;' => { output->first = 0x27e7; fbreak; };
  'RightDownTeeVector;' => { output->first = 0x295d; fbreak; };
  'RightDownVector;' => { output->first = 0x21c2; fbreak; };
  'RightDownVectorBar;' => { output->first = 0x2955; fbreak; };
  'RightFloor;' => { output->first = 0x230b; fbreak; };
  'RightTee;' => { output->first = 0x22a2; fbreak; };
  'RightTeeArrow;' => { output->first = 0x21a6; fbreak; };
  'RightTeeVector;' => { output->first = 0x295b; fbreak; };
  'RightTriangle;' => { output->first = 0x22b3; fbreak; };
  'RightTriangleBar;' => { output->first = 0x29d0; fbreak; };
  'RightTriangleEqual;' => { output->first = 0x22b5; fbreak; };
  'RightUpDownVector;' => { output->first = 0x294f; fbreak; };
  'RightUpTeeVector;' => { output->first = 0x295c; fbreak; };
  'RightUpVector;' => { output->first = 0x21be; fbreak; };
  'RightUpVectorBar;' => { output->first = 0x2954; fbreak; };
  'RightVector;' => { output->first = 0x21c0; fbreak; };
  'RightVectorBar;' => { output->first = 0x2953; fbreak; };
  'Rightarrow;' => { output->first = 0x21d2; fbreak; };
  'Ropf;' => { output->first = 0x211d; fbreak; };
  'RoundImplies;' => { output->first = 0x2970; fbreak; };
  'Rrightarrow;' => { output->first = 0x21db; fbreak; };
  'Rscr;' => { output->first = 0x211b; fbreak; };
  'Rsh;' => { output->first = 0x21b1; fbreak; };
  'RuleDelayed;' => { output->first = 0x29f4; fbreak; };
  'SHCHcy;' => { output->first = 0x0429; fbreak; };
  'SHcy;' => { output->first = 0x0428; fbreak; };
  'SOFTcy;' => { output->first = 0x042c; fbreak; };
  'Sacute;' => { output->first = 0x015a; fbreak; };
  'Sc;' => { output->first = 0x2abc; fbreak; };
  'Scaron;' => { output->first = 0x0160; fbreak; };
  'Scedil;' => { output->first = 0x015e; fbreak; };
  'Scirc;' => { output->first = 0x015c; fbreak; };
  'Scy;' => { output->first = 0x0421; fbreak; };
  'Sfr;' => { output->first = 0x0001d516; fbreak; };
  'ShortDownArrow;' => { output->first = 0x2193; fbreak; };
  'ShortLeftArrow;' => { output->first = 0x2190; fbreak; };
  'ShortRightArrow;' => { output->first = 0x2192; fbreak; };
  'ShortUpArrow;' => { output->first = 0x2191; fbreak; };
  'Sigma;' => { output->first = 0x03a3; fbreak; };
  'SmallCircle;' => { output->first = 0x2218; fbreak; };
  'Sopf;' => { output->first = 0x0001d54a; fbreak; };
  'Sqrt;' => { output->first = 0x221a; fbreak; };
  'Square;' => { output->first = 0x25a1; fbreak; };
  'SquareIntersection;' => { output->first = 0x2293; fbreak; };
  'SquareSubset;' => { output->first = 0x228f; fbreak; };
  'SquareSubsetEqual;' => { output->first = 0x2291; fbreak; };
  'SquareSuperset;' => { output->first = 0x2290; fbreak; };
  'SquareSupersetEqual;' => { output->first = 0x2292; fbreak; };
  'SquareUnion;' => { output->first = 0x2294; fbreak; };
  'Sscr;' => { output->first = 0x0001d4ae; fbreak; };
  'Star;' => { output->first = 0x22c6; fbreak; };
  'Sub;' => { output->first = 0x22d0; fbreak; };
  'Subset;' => { output->first = 0x22d0; fbreak; };
  'SubsetEqual;' => { output->first = 0x2286; fbreak; };
  'Succeeds;' => { output->first = 0x227b; fbreak; };
  'SucceedsEqual;' => { output->first = 0x2ab0; fbreak; };
  'SucceedsSlantEqual;' => { output->first = 0x227d; fbreak; };
  'SucceedsTilde;' => { output->first = 0x227f; fbreak; };
  'SuchThat;' => { output->first = 0x220b; fbreak; };
  'Sum;' => { output->first = 0x2211; fbreak; };
  'Sup;' => { output->first = 0x22d1; fbreak; };
  'Superset;' => { output->first = 0x2283; fbreak; };
  'SupersetEqual;' => { output->first = 0x2287; fbreak; };
  'Supset;' => { output->first = 0x22d1; fbreak; };
  'THORN;' => { output->first = 0xde; fbreak; };
  'THORN' => { output->first = 0xde; fbreak; };
  'TRADE;' => { output->first = 0x2122; fbreak; };
  'TSHcy;' => { output->first = 0x040b; fbreak; };
  'TScy;' => { output->first = 0x0426; fbreak; };
  'Tab;' => { output->first = 0x09; fbreak; };
  'Tau;' => { output->first = 0x03a4; fbreak; };
  'Tcaron;' => { output->first = 0x0164; fbreak; };
  'Tcedil;' => { output->first = 0x0162; fbreak; };
  'Tcy;' => { output->first = 0x0422; fbreak; };
  'Tfr;' => { output->first = 0x0001d517; fbreak; };
  'Therefore;' => { output->first = 0x2234; fbreak; };
  'Theta;' => { output->first = 0x0398; fbreak; };
  'ThickSpace;' => { output->first = 0x205f; output->second = 0x200a; fbreak; };
  'ThinSpace;' => { output->first = 0x2009; fbreak; };
  'Tilde;' => { output->first = 0x223c; fbreak; };
  'TildeEqual;' => { output->first = 0x2243; fbreak; };
  'TildeFullEqual;' => { output->first = 0x2245; fbreak; };
  'TildeTilde;' => { output->first = 0x2248; fbreak; };
  'Topf;' => { output->first = 0x0001d54b; fbreak; };
  'TripleDot;' => { output->first = 0x20db; fbreak; };
  'Tscr;' => { output->first = 0x0001d4af; fbreak; };
  'Tstrok;' => { output->first = 0x0166; fbreak; };
  'Uacute;' => { output->first = 0xda; fbreak; };
  'Uacute' => { output->first = 0xda; fbreak; };
  'Uarr;' => { output->first = 0x219f; fbreak; };
  'Uarrocir;' => { output->first = 0x2949; fbreak; };
  'Ubrcy;' => { output->first = 0x040e; fbreak; };
  'Ubreve;' => { output->first = 0x016c; fbreak; };
  'Ucirc;' => { output->first = 0xdb; fbreak; };
  'Ucirc' => { output->first = 0xdb; fbreak; };
  'Ucy;' => { output->first = 0x0423; fbreak; };
  'Udblac;' => { output->first = 0x0170; fbreak; };
  'Ufr;' => { output->first = 0x0001d518; fbreak; };
  'Ugrave;' => { output->first = 0xd9; fbreak; };
  'Ugrave' => { output->first = 0xd9; fbreak; };
  'Umacr;' => { output->first = 0x016a; fbreak; };
  'UnderBar;' => { output->first = 0x5f; fbreak; };
  'UnderBrace;' => { output->first = 0x23df; fbreak; };
  'UnderBracket;' => { output->first = 0x23b5; fbreak; };
  'UnderParenthesis;' => { output->first = 0x23dd; fbreak; };
  'Union;' => { output->first = 0x22c3; fbreak; };
  'UnionPlus;' => { output->first = 0x228e; fbreak; };
  'Uogon;' => { output->first = 0x0172; fbreak; };
  'Uopf;' => { output->first = 0x0001d54c; fbreak; };
  'UpArrow;' => { output->first = 0x2191; fbreak; };
  'UpArrowBar;' => { output->first = 0x2912; fbreak; };
  'UpArrowDownArrow;' => { output->first = 0x21c5; fbreak; };
  'UpDownArrow;' => { output->first = 0x2195; fbreak; };
  'UpEquilibrium;' => { output->first = 0x296e; fbreak; };
  'UpTee;' => { output->first = 0x22a5; fbreak; };
  'UpTeeArrow;' => { output->first = 0x21a5; fbreak; };
  'Uparrow;' => { output->first = 0x21d1; fbreak; };
  'Updownarrow;' => { output->first = 0x21d5; fbreak; };
  'UpperLeftArrow;' => { output->first = 0x2196; fbreak; };
  'UpperRightArrow;' => { output->first = 0x2197; fbreak; };
  'Upsi;' => { output->first = 0x03d2; fbreak; };
  'Upsilon;' => { output->first = 0x03a5; fbreak; };
  'Uring;' => { output->first = 0x016e; fbreak; };
  'Uscr;' => { output->first = 0x0001d4b0; fbreak; };
  'Utilde;' => { output->first = 0x0168; fbreak; };
  'Uuml;' => { output->first = 0xdc; fbreak; };
  'Uuml' => { output->first = 0xdc; fbreak; };
  'VDash;' => { output->first = 0x22ab; fbreak; };
  'Vbar;' => { output->first = 0x2aeb; fbreak; };
  'Vcy;' => { output->first = 0x0412; fbreak; };
  'Vdash;' => { output->first = 0x22a9; fbreak; };
  'Vdashl;' => { output->first = 0x2ae6; fbreak; };
  'Vee;' => { output->first = 0x22c1; fbreak; };
  'Verbar;' => { output->first = 0x2016; fbreak; };
  'Vert;' => { output->first = 0x2016; fbreak; };
  'VerticalBar;' => { output->first = 0x2223; fbreak; };
  'VerticalLine;' => { output->first = 0x7c; fbreak; };
  'VerticalSeparator;' => { output->first = 0x2758; fbreak; };
  'VerticalTilde;' => { output->first = 0x2240; fbreak; };
  'VeryThinSpace;' => { output->first = 0x200a; fbreak; };
  'Vfr;' => { output->first = 0x0001d519; fbreak; };
  'Vopf;' => { output->first = 0x0001d54d; fbreak; };
  'Vscr;' => { output->first = 0x0001d4b1; fbreak; };
  'Vvdash;' => { output->first = 0x22aa; fbreak; };
  'Wcirc;' => { output->first = 0x0174; fbreak; };
  'Wedge;' => { output->first = 0x22c0; fbreak; };
  'Wfr;' => { output->first = 0x0001d51a; fbreak; };
  'Wopf;' => { output->first = 0x0001d54e; fbreak; };
  'Wscr;' => { output->first = 0x0001d4b2; fbreak; };
  'Xfr;' => { output->first = 0x0001d51b; fbreak; };
  'Xi;' => { output->first = 0x039e; fbreak; };
  'Xopf;' => { output->first = 0x0001d54f; fbreak; };
  'Xscr;' => { output->first = 0x0001d4b3; fbreak; };
  'YAcy;' => { output->first = 0x042f; fbreak; };
  'YIcy;' => { output->first = 0x0407; fbreak; };
  'YUcy;' => { output->first = 0x042e; fbreak; };
  'Yacute;' => { output->first = 0xdd; fbreak; };
  'Yacute' => { output->first = 0xdd; fbreak; };
  'Ycirc;' => { output->first = 0x0176; fbreak; };
  'Ycy;' => { output->first = 0x042b; fbreak; };
  'Yfr;' => { output->first = 0x0001d51c; fbreak; };
  'Yopf;' => { output->first = 0x0001d550; fbreak; };
  'Yscr;' => { output->first = 0x0001d4b4; fbreak; };
  'Yuml;' => { output->first = 0x0178; fbreak; };
  'ZHcy;' => { output->first = 0x0416; fbreak; };
  'Zacute;' => { output->first = 0x0179; fbreak; };
  'Zcaron;' => { output->first = 0x017d; fbreak; };
  'Zcy;' => { output->first = 0x0417; fbreak; };
  'Zdot;' => { output->first = 0x017b; fbreak; };
  'ZeroWidthSpace;' => { output->first = 0x200b; fbreak; };
  'Zeta;' => { output->first = 0x0396; fbreak; };
  'Zfr;' => { output->first = 0x2128; fbreak; };
  'Zopf;' => { output->first = 0x2124; fbreak; };
  'Zscr;' => { output->first = 0x0001d4b5; fbreak; };
  'aacute;' => { output->first = 0xe1; fbreak; };
  'aacute' => { output->first = 0xe1; fbreak; };
  'abreve;' => { output->first = 0x0103; fbreak; };
  'ac;' => { output->first = 0x223e; fbreak; };
  'acE;' => { output->first = 0x223e; output->second = 0x0333; fbreak; };
  'acd;' => { output->first = 0x223f; fbreak; };
  'acirc;' => { output->first = 0xe2; fbreak; };
  'acirc' => { output->first = 0xe2; fbreak; };
  'acute;' => { output->first = 0xb4; fbreak; };
  'acute' => { output->first = 0xb4; fbreak; };
  'acy;' => { output->first = 0x0430; fbreak; };
  'aelig;' => { output->first = 0xe6; fbreak; };
  'aelig' => { output->first = 0xe6; fbreak; };
  'af;' => { output->first = 0x2061; fbreak; };
  'afr;' => { output->first = 0x0001d51e; fbreak; };
  'agrave;' => { output->first = 0xe0; fbreak; };
  'agrave' => { output->first = 0xe0; fbreak; };
  'alefsym;' => { output->first = 0x2135; fbreak; };
  'aleph;' => { output->first = 0x2135; fbreak; };
  'alpha;' => { output->first = 0x03b1; fbreak; };
  'amacr;' => { output->first = 0x0101; fbreak; };
  'amalg;' => { output->first = 0x2a3f; fbreak; };
  'amp;' => { output->first = 0x26; fbreak; };
  'amp' => { output->first = 0x26; fbreak; };
  'and;' => { output->first = 0x2227; fbreak; };
  'andand;' => { output->first = 0x2a55; fbreak; };
  'andd;' => { output->first = 0x2a5c; fbreak; };
  'andslope;' => { output->first = 0x2a58; fbreak; };
  'andv;' => { output->first = 0x2a5a; fbreak; };
  'ang;' => { output->first = 0x2220; fbreak; };
  'ange;' => { output->first = 0x29a4; fbreak; };
  'angle;' => { output->first = 0x2220; fbreak; };
  'angmsd;' => { output->first = 0x2221; fbreak; };
  'angmsdaa;' => { output->first = 0x29a8; fbreak; };
  'angmsdab;' => { output->first = 0x29a9; fbreak; };
  'angmsdac;' => { output->first = 0x29aa; fbreak; };
  'angmsdad;' => { output->first = 0x29ab; fbreak; };
  'angmsdae;' => { output->first = 0x29ac; fbreak; };
  'angmsdaf;' => { output->first = 0x29ad; fbreak; };
  'angmsdag;' => { output->first = 0x29ae; fbreak; };
  'angmsdah;' => { output->first = 0x29af; fbreak; };
  'angrt;' => { output->first = 0x221f; fbreak; };
  'angrtvb;' => { output->first = 0x22be; fbreak; };
  'angrtvbd;' => { output->first = 0x299d; fbreak; };
  'angsph;' => { output->first = 0x2222; fbreak; };
  'angst;' => { output->first = 0xc5; fbreak; };
  'angzarr;' => { output->first = 0x237c; fbreak; };
  'aogon;' => { output->first = 0x0105; fbreak; };
  'aopf;' => { output->first = 0x0001d552; fbreak; };
  'ap;' => { output->first = 0x2248; fbreak; };
  'apE;' => { output->first = 0x2a70; fbreak; };
  'apacir;' => { output->first = 0x2a6f; fbreak; };
  'ape;' => { output->first = 0x224a; fbreak; };
  'apid;' => { output->first = 0x224b; fbreak; };
  'apos;' => { output->first = 0x27; fbreak; };
  'approx;' => { output->first = 0x2248; fbreak; };
  'approxeq;' => { output->first = 0x224a; fbreak; };
  'aring;' => { output->first = 0xe5; fbreak; };
  'aring' => { output->first = 0xe5; fbreak; };
  'ascr;' => { output->first = 0x0001d4b6; fbreak; };
  'ast;' => { output->first = 0x2a; fbreak; };
  'asymp;' => { output->first = 0x2248; fbreak; };
  'asympeq;' => { output->first = 0x224d; fbreak; };
  'atilde;' => { output->first = 0xe3; fbreak; };
  'atilde' => { output->first = 0xe3; fbreak; };
  'auml;' => { output->first = 0xe4; fbreak; };
  'auml' => { output->first = 0xe4; fbreak; };
  'awconint;' => { output->first = 0x2233; fbreak; };
  'awint;' => { output->first = 0x2a11; fbreak; };
  'bNot;' => { output->first = 0x2aed; fbreak; };
  'backcong;' => { output->first = 0x224c; fbreak; };
  'backepsilon;' => { output->first = 0x03f6; fbreak; };
  'backprime;' => { output->first = 0x2035; fbreak; };
  'backsim;' => { output->first = 0x223d; fbreak; };
  'backsimeq;' => { output->first = 0x22cd; fbreak; };
  'barvee;' => { output->first = 0x22bd; fbreak; };
  'barwed;' => { output->first = 0x2305; fbreak; };
  'barwedge;' => { output->first = 0x2305; fbreak; };
  'bbrk;' => { output->first = 0x23b5; fbreak; };
  'bbrktbrk;' => { output->first = 0x23b6; fbreak; };
  'bcong;' => { output->first = 0x224c; fbreak; };
  'bcy;' => { output->first = 0x0431; fbreak; };
  'bdquo;' => { output->first = 0x201e; fbreak; };
  'becaus;' => { output->first = 0x2235; fbreak; };
  'because;' => { output->first = 0x2235; fbreak; };
  'bemptyv;' => { output->first = 0x29b0; fbreak; };
  'bepsi;' => { output->first = 0x03f6; fbreak; };
  'bernou;' => { output->first = 0x212c; fbreak; };
  'beta;' => { output->first = 0x03b2; fbreak; };
  'beth;' => { output->first = 0x2136; fbreak; };
  'between;' => { output->first = 0x226c; fbreak; };
  'bfr;' => { output->first = 0x0001d51f; fbreak; };
  'bigcap;' => { output->first = 0x22c2; fbreak; };
  'bigcirc;' => { output->first = 0x25ef; fbreak; };
  'bigcup;' => { output->first = 0x22c3; fbreak; };
  'bigodot;' => { output->first = 0x2a00; fbreak; };
  'bigoplus;' => { output->first = 0x2a01; fbreak; };
  'bigotimes;' => { output->first = 0x2a02; fbreak; };
  'bigsqcup;' => { output->first = 0x2a06; fbreak; };
  'bigstar;' => { output->first = 0x2605; fbreak; };
  'bigtriangledown;' => { output->first = 0x25bd; fbreak; };
  'bigtriangleup;' => { output->first = 0x25b3; fbreak; };
  'biguplus;' => { output->first = 0x2a04; fbreak; };
  'bigvee;' => { output->first = 0x22c1; fbreak; };
  'bigwedge;' => { output->first = 0x22c0; fbreak; };
  'bkarow;' => { output->first = 0x290d; fbreak; };
  'blacklozenge;' => { output->first = 0x29eb; fbreak; };
  'blacksquare;' => { output->first = 0x25aa; fbreak; };
  'blacktriangle;' => { output->first = 0x25b4; fbreak; };
  'blacktriangledown;' => { output->first = 0x25be; fbreak; };
  'blacktriangleleft;' => { output->first = 0x25c2; fbreak; };
  'blacktriangleright;' => { output->first = 0x25b8; fbreak; };
  'blank;' => { output->first = 0x2423; fbreak; };
  'blk12;' => { output->first = 0x2592; fbreak; };
  'blk14;' => { output->first = 0x2591; fbreak; };
  'blk34;' => { output->first = 0x2593; fbreak; };
  'block;' => { output->first = 0x2588; fbreak; };
  'bne;' => { output->first = 0x3d; output->second = 0x20e5; fbreak; };
  'bnequiv;' => { output->first = 0x2261; output->second = 0x20e5; fbreak; };
  'bnot;' => { output->first = 0x2310; fbreak; };
  'bopf;' => { output->first = 0x0001d553; fbreak; };
  'bot;' => { output->first = 0x22a5; fbreak; };
  'bottom;' => { output->first = 0x22a5; fbreak; };
  'bowtie;' => { output->first = 0x22c8; fbreak; };
  'boxDL;' => { output->first = 0x2557; fbreak; };
  'boxDR;' => { output->first = 0x2554; fbreak; };
  'boxDl;' => { output->first = 0x2556; fbreak; };
  'boxDr;' => { output->first = 0x2553; fbreak; };
  'boxH;' => { output->first = 0x2550; fbreak; };
  'boxHD;' => { output->first = 0x2566; fbreak; };
  'boxHU;' => { output->first = 0x2569; fbreak; };
  'boxHd;' => { output->first = 0x2564; fbreak; };
  'boxHu;' => { output->first = 0x2567; fbreak; };
  'boxUL;' => { output->first = 0x255d; fbreak; };
  'boxUR;' => { output->first = 0x255a; fbreak; };
  'boxUl;' => { output->first = 0x255c; fbreak; };
  'boxUr;' => { output->first = 0x2559; fbreak; };
  'boxV;' => { output->first = 0x2551; fbreak; };
  'boxVH;' => { output->first = 0x256c; fbreak; };
  'boxVL;' => { output->first = 0x2563; fbreak; };
  'boxVR;' => { output->first = 0x2560; fbreak; };
  'boxVh;' => { output->first = 0x256b; fbreak; };
  'boxVl;' => { output->first = 0x2562; fbreak; };
  'boxVr;' => { output->first = 0x255f; fbreak; };
  'boxbox;' => { output->first = 0x29c9; fbreak; };
  'boxdL;' => { output->first = 0x2555; fbreak; };
  'boxdR;' => { output->first = 0x2552; fbreak; };
  'boxdl;' => { output->first = 0x2510; fbreak; };
  'boxdr;' => { output->first = 0x250c; fbreak; };
  'boxh;' => { output->first = 0x2500; fbreak; };
  'boxhD;' => { output->first = 0x2565; fbreak; };
  'boxhU;' => { output->first = 0x2568; fbreak; };
  'boxhd;' => { output->first = 0x252c; fbreak; };
  'boxhu;' => { output->first = 0x2534; fbreak; };
  'boxminus;' => { output->first = 0x229f; fbreak; };
  'boxplus;' => { output->first = 0x229e; fbreak; };
  'boxtimes;' => { output->first = 0x22a0; fbreak; };
  'boxuL;' => { output->first = 0x255b; fbreak; };
  'boxuR;' => { output->first = 0x2558; fbreak; };
  'boxul;' => { output->first = 0x2518; fbreak; };
  'boxur;' => { output->first = 0x2514; fbreak; };
  'boxv;' => { output->first = 0x2502; fbreak; };
  'boxvH;' => { output->first = 0x256a; fbreak; };
  'boxvL;' => { output->first = 0x2561; fbreak; };
  'boxvR;' => { output->first = 0x255e; fbreak; };
  'boxvh;' => { output->first = 0x253c; fbreak; };
  'boxvl;' => { output->first = 0x2524; fbreak; };
  'boxvr;' => { output->first = 0x251c; fbreak; };
  'bprime;' => { output->first = 0x2035; fbreak; };
  'breve;' => { output->first = 0x02d8; fbreak; };
  'brvbar;' => { output->first = 0xa6; fbreak; };
  'brvbar' => { output->first = 0xa6; fbreak; };
  'bscr;' => { output->first = 0x0001d4b7; fbreak; };
  'bsemi;' => { output->first = 0x204f; fbreak; };
  'bsim;' => { output->first = 0x223d; fbreak; };
  'bsime;' => { output->first = 0x22cd; fbreak; };
  'bsol;' => { output->first = 0x5c; fbreak; };
  'bsolb;' => { output->first = 0x29c5; fbreak; };
  'bsolhsub;' => { output->first = 0x27c8; fbreak; };
  'bull;' => { output->first = 0x2022; fbreak; };
  'bullet;' => { output->first = 0x2022; fbreak; };
  'bump;' => { output->first = 0x224e; fbreak; };
  'bumpE;' => { output->first = 0x2aae; fbreak; };
  'bumpe;' => { output->first = 0x224f; fbreak; };
  'bumpeq;' => { output->first = 0x224f; fbreak; };
  'cacute;' => { output->first = 0x0107; fbreak; };
  'cap;' => { output->first = 0x2229; fbreak; };
  'capand;' => { output->first = 0x2a44; fbreak; };
  'capbrcup;' => { output->first = 0x2a49; fbreak; };
  'capcap;' => { output->first = 0x2a4b; fbreak; };
  'capcup;' => { output->first = 0x2a47; fbreak; };
  'capdot;' => { output->first = 0x2a40; fbreak; };
  'caps;' => { output->first = 0x2229; output->second = 0xfe00; fbreak; };
  'caret;' => { output->first = 0x2041; fbreak; };
  'caron;' => { output->first = 0x02c7; fbreak; };
  'ccaps;' => { output->first = 0x2a4d; fbreak; };
  'ccaron;' => { output->first = 0x010d; fbreak; };
  'ccedil;' => { output->first = 0xe7; fbreak; };
  'ccedil' => { output->first = 0xe7; fbreak; };
  'ccirc;' => { output->first = 0x0109; fbreak; };
  'ccups;' => { output->first = 0x2a4c; fbreak; };
  'ccupssm;' => { output->first = 0x2a50; fbreak; };
  'cdot;' => { output->first = 0x010b; fbreak; };
  'cedil;' => { output->first = 0xb8; fbreak; };
  'cedil' => { output->first = 0xb8; fbreak; };
  'cemptyv;' => { output->first = 0x29b2; fbreak; };
  'cent;' => { output->first = 0xa2; fbreak; };
  'cent' => { output->first = 0xa2; fbreak; };
  'centerdot;' => { output->first = 0xb7; fbreak; };
  'cfr;' => { output->first = 0x0001d520; fbreak; };
  'chcy;' => { output->first = 0x0447; fbreak; };
  'check;' => { output->first = 0x2713; fbreak; };
  'checkmark;' => { output->first = 0x2713; fbreak; };
  'chi;' => { output->first = 0x03c7; fbreak; };
  'cir;' => { output->first = 0x25cb; fbreak; };
  'cirE;' => { output->first = 0x29c3; fbreak; };
  'circ;' => { output->first = 0x02c6; fbreak; };
  'circeq;' => { output->first = 0x2257; fbreak; };
  'circlearrowleft;' => { output->first = 0x21ba; fbreak; };
  'circlearrowright;' => { output->first = 0x21bb; fbreak; };
  'circledR;' => { output->first = 0xae; fbreak; };
  'circledS;' => { output->first = 0x24c8; fbreak; };
  'circledast;' => { output->first = 0x229b; fbreak; };
  'circledcirc;' => { output->first = 0x229a; fbreak; };
  'circleddash;' => { output->first = 0x229d; fbreak; };
  'cire;' => { output->first = 0x2257; fbreak; };
  'cirfnint;' => { output->first = 0x2a10; fbreak; };
  'cirmid;' => { output->first = 0x2aef; fbreak; };
  'cirscir;' => { output->first = 0x29c2; fbreak; };
  'clubs;' => { output->first = 0x2663; fbreak; };
  'clubsuit;' => { output->first = 0x2663; fbreak; };
  'colon;' => { output->first = 0x3a; fbreak; };
  'colone;' => { output->first = 0x2254; fbreak; };
  'coloneq;' => { output->first = 0x2254; fbreak; };
  'comma;' => { output->first = 0x2c; fbreak; };
  'commat;' => { output->first = 0x40; fbreak; };
  'comp;' => { output->first = 0x2201; fbreak; };
  'compfn;' => { output->first = 0x2218; fbreak; };
  'complement;' => { output->first = 0x2201; fbreak; };
  'complexes;' => { output->first = 0x2102; fbreak; };
  'cong;' => { output->first = 0x2245; fbreak; };
  'congdot;' => { output->first = 0x2a6d; fbreak; };
  'conint;' => { output->first = 0x222e; fbreak; };
  'copf;' => { output->first = 0x0001d554; fbreak; };
  'coprod;' => { output->first = 0x2210; fbreak; };
  'copy;' => { output->first = 0xa9; fbreak; };
  'copy' => { output->first = 0xa9; fbreak; };
  'copysr;' => { output->first = 0x2117; fbreak; };
  'crarr;' => { output->first = 0x21b5; fbreak; };
  'cross;' => { output->first = 0x2717; fbreak; };
  'cscr;' => { output->first = 0x0001d4b8; fbreak; };
  'csub;' => { output->first = 0x2acf; fbreak; };
  'csube;' => { output->first = 0x2ad1; fbreak; };
  'csup;' => { output->first = 0x2ad0; fbreak; };
  'csupe;' => { output->first = 0x2ad2; fbreak; };
  'ctdot;' => { output->first = 0x22ef; fbreak; };
  'cudarrl;' => { output->first = 0x2938; fbreak; };
  'cudarrr;' => { output->first = 0x2935; fbreak; };
  'cuepr;' => { output->first = 0x22de; fbreak; };
  'cuesc;' => { output->first = 0x22df; fbreak; };
  'cularr;' => { output->first = 0x21b6; fbreak; };
  'cularrp;' => { output->first = 0x293d; fbreak; };
  'cup;' => { output->first = 0x222a; fbreak; };
  'cupbrcap;' => { output->first = 0x2a48; fbreak; };
  'cupcap;' => { output->first = 0x2a46; fbreak; };
  'cupcup;' => { output->first = 0x2a4a; fbreak; };
  'cupdot;' => { output->first = 0x228d; fbreak; };
  'cupor;' => { output->first = 0x2a45; fbreak; };
  'cups;' => { output->first = 0x222a; output->second = 0xfe00; fbreak; };
  'curarr;' => { output->first = 0x21b7; fbreak; };
  'curarrm;' => { output->first = 0x293c; fbreak; };
  'curlyeqprec;' => { output->first = 0x22de; fbreak; };
  'curlyeqsucc;' => { output->first = 0x22df; fbreak; };
  'curlyvee;' => { output->first = 0x22ce; fbreak; };
  'curlywedge;' => { output->first = 0x22cf; fbreak; };
  'curren;' => { output->first = 0xa4; fbreak; };
  'curren' => { output->first = 0xa4; fbreak; };
  'curvearrowleft;' => { output->first = 0x21b6; fbreak; };
  'curvearrowright;' => { output->first = 0x21b7; fbreak; };
  'cuvee;' => { output->first = 0x22ce; fbreak; };
  'cuwed;' => { output->first = 0x22cf; fbreak; };
  'cwconint;' => { output->first = 0x2232; fbreak; };
  'cwint;' => { output->first = 0x2231; fbreak; };
  'cylcty;' => { output->first = 0x232d; fbreak; };
  'dArr;' => { output->first = 0x21d3; fbreak; };
  'dHar;' => { output->first = 0x2965; fbreak; };
  'dagger;' => { output->first = 0x2020; fbreak; };
  'daleth;' => { output->first = 0x2138; fbreak; };
  'darr;' => { output->first = 0x2193; fbreak; };
  'dash;' => { output->first = 0x2010; fbreak; };
  'dashv;' => { output->first = 0x22a3; fbreak; };
  'dbkarow;' => { output->first = 0x290f; fbreak; };
  'dblac;' => { output->first = 0x02dd; fbreak; };
  'dcaron;' => { output->first = 0x010f; fbreak; };
  'dcy;' => { output->first = 0x0434; fbreak; };
  'dd;' => { output->first = 0x2146; fbreak; };
  'ddagger;' => { output->first = 0x2021; fbreak; };
  'ddarr;' => { output->first = 0x21ca; fbreak; };
  'ddotseq;' => { output->first = 0x2a77; fbreak; };
  'deg;' => { output->first = 0xb0; fbreak; };
  'deg' => { output->first = 0xb0; fbreak; };
  'delta;' => { output->first = 0x03b4; fbreak; };
  'demptyv;' => { output->first = 0x29b1; fbreak; };
  'dfisht;' => { output->first = 0x297f; fbreak; };
  'dfr;' => { output->first = 0x0001d521; fbreak; };
  'dharl;' => { output->first = 0x21c3; fbreak; };
  'dharr;' => { output->first = 0x21c2; fbreak; };
  'diam;' => { output->first = 0x22c4; fbreak; };
  'diamond;' => { output->first = 0x22c4; fbreak; };
  'diamondsuit;' => { output->first = 0x2666; fbreak; };
  'diams;' => { output->first = 0x2666; fbreak; };
  'die;' => { output->first = 0xa8; fbreak; };
  'digamma;' => { output->first = 0x03dd; fbreak; };
  'disin;' => { output->first = 0x22f2; fbreak; };
  'div;' => { output->first = 0xf7; fbreak; };
  'divide;' => { output->first = 0xf7; fbreak; };
  'divide' => { output->first = 0xf7; fbreak; };
  'divideontimes;' => { output->first = 0x22c7; fbreak; };
  'divonx;' => { output->first = 0x22c7; fbreak; };
  'djcy;' => { output->first = 0x0452; fbreak; };
  'dlcorn;' => { output->first = 0x231e; fbreak; };
  'dlcrop;' => { output->first = 0x230d; fbreak; };
  'dollar;' => { output->first = 0x24; fbreak; };
  'dopf;' => { output->first = 0x0001d555; fbreak; };
  'dot;' => { output->first = 0x02d9; fbreak; };
  'doteq;' => { output->first = 0x2250; fbreak; };
  'doteqdot;' => { output->first = 0x2251; fbreak; };
  'dotminus;' => { output->first = 0x2238; fbreak; };
  'dotplus;' => { output->first = 0x2214; fbreak; };
  'dotsquare;' => { output->first = 0x22a1; fbreak; };
  'doublebarwedge;' => { output->first = 0x2306; fbreak; };
  'downarrow;' => { output->first = 0x2193; fbreak; };
  'downdownarrows;' => { output->first = 0x21ca; fbreak; };
  'downharpoonleft;' => { output->first = 0x21c3; fbreak; };
  'downharpoonright;' => { output->first = 0x21c2; fbreak; };
  'drbkarow;' => { output->first = 0x2910; fbreak; };
  'drcorn;' => { output->first = 0x231f; fbreak; };
  'drcrop;' => { output->first = 0x230c; fbreak; };
  'dscr;' => { output->first = 0x0001d4b9; fbreak; };
  'dscy;' => { output->first = 0x0455; fbreak; };
  'dsol;' => { output->first = 0x29f6; fbreak; };
  'dstrok;' => { output->first = 0x0111; fbreak; };
  'dtdot;' => { output->first = 0x22f1; fbreak; };
  'dtri;' => { output->first = 0x25bf; fbreak; };
  'dtrif;' => { output->first = 0x25be; fbreak; };
  'duarr;' => { output->first = 0x21f5; fbreak; };
  'duhar;' => { output->first = 0x296f; fbreak; };
  'dwangle;' => { output->first = 0x29a6; fbreak; };
  'dzcy;' => { output->first = 0x045f; fbreak; };
  'dzigrarr;' => { output->first = 0x27ff; fbreak; };
  'eDDot;' => { output->first = 0x2a77; fbreak; };
  'eDot;' => { output->first = 0x2251; fbreak; };
  'eacute;' => { output->first = 0xe9; fbreak; };
  'eacute' => { output->first = 0xe9; fbreak; };
  'easter;' => { output->first = 0x2a6e; fbreak; };
  'ecaron;' => { output->first = 0x011b; fbreak; };
  'ecir;' => { output->first = 0x2256; fbreak; };
  'ecirc;' => { output->first = 0xea; fbreak; };
  'ecirc' => { output->first = 0xea; fbreak; };
  'ecolon;' => { output->first = 0x2255; fbreak; };
  'ecy;' => { output->first = 0x044d; fbreak; };
  'edot;' => { output->first = 0x0117; fbreak; };
  'ee;' => { output->first = 0x2147; fbreak; };
  'efDot;' => { output->first = 0x2252; fbreak; };
  'efr;' => { output->first = 0x0001d522; fbreak; };
  'eg;' => { output->first = 0x2a9a; fbreak; };
  'egrave;' => { output->first = 0xe8; fbreak; };
  'egrave' => { output->first = 0xe8; fbreak; };
  'egs;' => { output->first = 0x2a96; fbreak; };
  'egsdot;' => { output->first = 0x2a98; fbreak; };
  'el;' => { output->first = 0x2a99; fbreak; };
  'elinters;' => { output->first = 0x23e7; fbreak; };
  'ell;' => { output->first = 0x2113; fbreak; };
  'els;' => { output->first = 0x2a95; fbreak; };
  'elsdot;' => { output->first = 0x2a97; fbreak; };
  'emacr;' => { output->first = 0x0113; fbreak; };
  'empty;' => { output->first = 0x2205; fbreak; };
  'emptyset;' => { output->first = 0x2205; fbreak; };
  'emptyv;' => { output->first = 0x2205; fbreak; };
  'emsp13;' => { output->first = 0x2004; fbreak; };
  'emsp14;' => { output->first = 0x2005; fbreak; };
  'emsp;' => { output->first = 0x2003; fbreak; };
  'eng;' => { output->first = 0x014b; fbreak; };
  'ensp;' => { output->first = 0x2002; fbreak; };
  'eogon;' => { output->first = 0x0119; fbreak; };
  'eopf;' => { output->first = 0x0001d556; fbreak; };
  'epar;' => { output->first = 0x22d5; fbreak; };
  'eparsl;' => { output->first = 0x29e3; fbreak; };
  'eplus;' => { output->first = 0x2a71; fbreak; };
  'epsi;' => { output->first = 0x03b5; fbreak; };
  'epsilon;' => { output->first = 0x03b5; fbreak; };
  'epsiv;' => { output->first = 0x03f5; fbreak; };
  'eqcirc;' => { output->first = 0x2256; fbreak; };
  'eqcolon;' => { output->first = 0x2255; fbreak; };
  'eqsim;' => { output->first = 0x2242; fbreak; };
  'eqslantgtr;' => { output->first = 0x2a96; fbreak; };
  'eqslantless;' => { output->first = 0x2a95; fbreak; };
  'equals;' => { output->first = 0x3d; fbreak; };
  'equest;' => { output->first = 0x225f; fbreak; };
  'equiv;' => { output->first = 0x2261; fbreak; };
  'equivDD;' => { output->first = 0x2a78; fbreak; };
  'eqvparsl;' => { output->first = 0x29e5; fbreak; };
  'erDot;' => { output->first = 0x2253; fbreak; };
  'erarr;' => { output->first = 0x2971; fbreak; };
  'escr;' => { output->first = 0x212f; fbreak; };
  'esdot;' => { output->first = 0x2250; fbreak; };
  'esim;' => { output->first = 0x2242; fbreak; };
  'eta;' => { output->first = 0x03b7; fbreak; };
  'eth;' => { output->first = 0xf0; fbreak; };
  'eth' => { output->first = 0xf0; fbreak; };
  'euml;' => { output->first = 0xeb; fbreak; };
  'euml' => { output->first = 0xeb; fbreak; };
  'euro;' => { output->first = 0x20ac; fbreak; };
  'excl;' => { output->first = 0x21; fbreak; };
  'exist;' => { output->first = 0x2203; fbreak; };
  'expectation;' => { output->first = 0x2130; fbreak; };
  'exponentiale;' => { output->first = 0x2147; fbreak; };
  'fallingdotseq;' => { output->first = 0x2252; fbreak; };
  'fcy;' => { output->first = 0x0444; fbreak; };
  'female;' => { output->first = 0x2640; fbreak; };
  'ffilig;' => { output->first = 0xfb03; fbreak; };
  'fflig;' => { output->first = 0xfb00; fbreak; };
  'ffllig;' => { output->first = 0xfb04; fbreak; };
  'ffr;' => { output->first = 0x0001d523; fbreak; };
  'filig;' => { output->first = 0xfb01; fbreak; };
  'fjlig;' => { output->first = 0x66; output->second = 0x6a; fbreak; };
  'flat;' => { output->first = 0x266d; fbreak; };
  'fllig;' => { output->first = 0xfb02; fbreak; };
  'fltns;' => { output->first = 0x25b1; fbreak; };
  'fnof;' => { output->first = 0x0192; fbreak; };
  'fopf;' => { output->first = 0x0001d557; fbreak; };
  'forall;' => { output->first = 0x2200; fbreak; };
  'fork;' => { output->first = 0x22d4; fbreak; };
  'forkv;' => { output->first = 0x2ad9; fbreak; };
  'fpartint;' => { output->first = 0x2a0d; fbreak; };
  'frac12;' => { output->first = 0xbd; fbreak; };
  'frac12' => { output->first = 0xbd; fbreak; };
  'frac13;' => { output->first = 0x2153; fbreak; };
  'frac14;' => { output->first = 0xbc; fbreak; };
  'frac14' => { output->first = 0xbc; fbreak; };
  'frac15;' => { output->first = 0x2155; fbreak; };
  'frac16;' => { output->first = 0x2159; fbreak; };
  'frac18;' => { output->first = 0x215b; fbreak; };
  'frac23;' => { output->first = 0x2154; fbreak; };
  'frac25;' => { output->first = 0x2156; fbreak; };
  'frac34;' => { output->first = 0xbe; fbreak; };
  'frac34' => { output->first = 0xbe; fbreak; };
  'frac35;' => { output->first = 0x2157; fbreak; };
  'frac38;' => { output->first = 0x215c; fbreak; };
  'frac45;' => { output->first = 0x2158; fbreak; };
  'frac56;' => { output->first = 0x215a; fbreak; };
  'frac58;' => { output->first = 0x215d; fbreak; };
  'frac78;' => { output->first = 0x215e; fbreak; };
  'frasl;' => { output->first = 0x2044; fbreak; };
  'frown;' => { output->first = 0x2322; fbreak; };
  'fscr;' => { output->first = 0x0001d4bb; fbreak; };
  'gE;' => { output->first = 0x2267; fbreak; };
  'gEl;' => { output->first = 0x2a8c; fbreak; };
  'gacute;' => { output->first = 0x01f5; fbreak; };
  'gamma;' => { output->first = 0x03b3; fbreak; };
  'gammad;' => { output->first = 0x03dd; fbreak; };
  'gap;' => { output->first = 0x2a86; fbreak; };
  'gbreve;' => { output->first = 0x011f; fbreak; };
  'gcirc;' => { output->first = 0x011d; fbreak; };
  'gcy;' => { output->first = 0x0433; fbreak; };
  'gdot;' => { output->first = 0x0121; fbreak; };
  'ge;' => { output->first = 0x2265; fbreak; };
  'gel;' => { output->first = 0x22db; fbreak; };
  'geq;' => { output->first = 0x2265; fbreak; };
  'geqq;' => { output->first = 0x2267; fbreak; };
  'geqslant;' => { output->first = 0x2a7e; fbreak; };
  'ges;' => { output->first = 0x2a7e; fbreak; };
  'gescc;' => { output->first = 0x2aa9; fbreak; };
  'gesdot;' => { output->first = 0x2a80; fbreak; };
  'gesdoto;' => { output->first = 0x2a82; fbreak; };
  'gesdotol;' => { output->first = 0x2a84; fbreak; };
  'gesl;' => { output->first = 0x22db; output->second = 0xfe00; fbreak; };
  'gesles;' => { output->first = 0x2a94; fbreak; };
  'gfr;' => { output->first = 0x0001d524; fbreak; };
  'gg;' => { output->first = 0x226b; fbreak; };
  'ggg;' => { output->first = 0x22d9; fbreak; };
  'gimel;' => { output->first = 0x2137; fbreak; };
  'gjcy;' => { output->first = 0x0453; fbreak; };
  'gl;' => { output->first = 0x2277; fbreak; };
  'glE;' => { output->first = 0x2a92; fbreak; };
  'gla;' => { output->first = 0x2aa5; fbreak; };
  'glj;' => { output->first = 0x2aa4; fbreak; };
  'gnE;' => { output->first = 0x2269; fbreak; };
  'gnap;' => { output->first = 0x2a8a; fbreak; };
  'gnapprox;' => { output->first = 0x2a8a; fbreak; };
  'gne;' => { output->first = 0x2a88; fbreak; };
  'gneq;' => { output->first = 0x2a88; fbreak; };
  'gneqq;' => { output->first = 0x2269; fbreak; };
  'gnsim;' => { output->first = 0x22e7; fbreak; };
  'gopf;' => { output->first = 0x0001d558; fbreak; };
  'grave;' => { output->first = 0x60; fbreak; };
  'gscr;' => { output->first = 0x210a; fbreak; };
  'gsim;' => { output->first = 0x2273; fbreak; };
  'gsime;' => { output->first = 0x2a8e; fbreak; };
  'gsiml;' => { output->first = 0x2a90; fbreak; };
  'gt;' => { output->first = 0x3e; fbreak; };
  'gt' => { output->first = 0x3e; fbreak; };
  'gtcc;' => { output->first = 0x2aa7; fbreak; };
  'gtcir;' => { output->first = 0x2a7a; fbreak; };
  'gtdot;' => { output->first = 0x22d7; fbreak; };
  'gtlPar;' => { output->first = 0x2995; fbreak; };
  'gtquest;' => { output->first = 0x2a7c; fbreak; };
  'gtrapprox;' => { output->first = 0x2a86; fbreak; };
  'gtrarr;' => { output->first = 0x2978; fbreak; };
  'gtrdot;' => { output->first = 0x22d7; fbreak; };
  'gtreqless;' => { output->first = 0x22db; fbreak; };
  'gtreqqless;' => { output->first = 0x2a8c; fbreak; };
  'gtrless;' => { output->first = 0x2277; fbreak; };
  'gtrsim;' => { output->first = 0x2273; fbreak; };
  'gvertneqq;' => { output->first = 0x2269; output->second = 0xfe00; fbreak; };
  'gvnE;' => { output->first = 0x2269; output->second = 0xfe00; fbreak; };
  'hArr;' => { output->first = 0x21d4; fbreak; };
  'hairsp;' => { output->first = 0x200a; fbreak; };
  'half;' => { output->first = 0xbd; fbreak; };
  'hamilt;' => { output->first = 0x210b; fbreak; };
  'hardcy;' => { output->first = 0x044a; fbreak; };
  'harr;' => { output->first = 0x2194; fbreak; };
  'harrcir;' => { output->first = 0x2948; fbreak; };
  'harrw;' => { output->first = 0x21ad; fbreak; };
  'hbar;' => { output->first = 0x210f; fbreak; };
  'hcirc;' => { output->first = 0x0125; fbreak; };
  'hearts;' => { output->first = 0x2665; fbreak; };
  'heartsuit;' => { output->first = 0x2665; fbreak; };
  'hellip;' => { output->first = 0x2026; fbreak; };
  'hercon;' => { output->first = 0x22b9; fbreak; };
  'hfr;' => { output->first = 0x0001d525; fbreak; };
  'hksearow;' => { output->first = 0x2925; fbreak; };
  'hkswarow;' => { output->first = 0x2926; fbreak; };
  'hoarr;' => { output->first = 0x21ff; fbreak; };
  'homtht;' => { output->first = 0x223b; fbreak; };
  'hookleftarrow;' => { output->first = 0x21a9; fbreak; };
  'hookrightarrow;' => { output->first = 0x21aa; fbreak; };
  'hopf;' => { output->first = 0x0001d559; fbreak; };
  'horbar;' => { output->first = 0x2015; fbreak; };
  'hscr;' => { output->first = 0x0001d4bd; fbreak; };
  'hslash;' => { output->first = 0x210f; fbreak; };
  'hstrok;' => { output->first = 0x0127; fbreak; };
  'hybull;' => { output->first = 0x2043; fbreak; };
  'hyphen;' => { output->first = 0x2010; fbreak; };
  'iacute;' => { output->first = 0xed; fbreak; };
  'iacute' => { output->first = 0xed; fbreak; };
  'ic;' => { output->first = 0x2063; fbreak; };
  'icirc;' => { output->first = 0xee; fbreak; };
  'icirc' => { output->first = 0xee; fbreak; };
  'icy;' => { output->first = 0x0438; fbreak; };
  'iecy;' => { output->first = 0x0435; fbreak; };
  'iexcl;' => { output->first = 0xa1; fbreak; };
  'iexcl' => { output->first = 0xa1; fbreak; };
  'iff;' => { output->first = 0x21d4; fbreak; };
  'ifr;' => { output->first = 0x0001d526; fbreak; };
  'igrave;' => { output->first = 0xec; fbreak; };
  'igrave' => { output->first = 0xec; fbreak; };
  'ii;' => { output->first = 0x2148; fbreak; };
  'iiiint;' => { output->first = 0x2a0c; fbreak; };
  'iiint;' => { output->first = 0x222d; fbreak; };
  'iinfin;' => { output->first = 0x29dc; fbreak; };
  'iiota;' => { output->first = 0x2129; fbreak; };
  'ijlig;' => { output->first = 0x0133; fbreak; };
  'imacr;' => { output->first = 0x012b; fbreak; };
  'image;' => { output->first = 0x2111; fbreak; };
  'imagline;' => { output->first = 0x2110; fbreak; };
  'imagpart;' => { output->first = 0x2111; fbreak; };
  'imath;' => { output->first = 0x0131; fbreak; };
  'imof;' => { output->first = 0x22b7; fbreak; };
  'imped;' => { output->first = 0x01b5; fbreak; };
  'in;' => { output->first = 0x2208; fbreak; };
  'incare;' => { output->first = 0x2105; fbreak; };
  'infin;' => { output->first = 0x221e; fbreak; };
  'infintie;' => { output->first = 0x29dd; fbreak; };
  'inodot;' => { output->first = 0x0131; fbreak; };
  'int;' => { output->first = 0x222b; fbreak; };
  'intcal;' => { output->first = 0x22ba; fbreak; };
  'integers;' => { output->first = 0x2124; fbreak; };
  'intercal;' => { output->first = 0x22ba; fbreak; };
  'intlarhk;' => { output->first = 0x2a17; fbreak; };
  'intprod;' => { output->first = 0x2a3c; fbreak; };
  'iocy;' => { output->first = 0x0451; fbreak; };
  'iogon;' => { output->first = 0x012f; fbreak; };
  'iopf;' => { output->first = 0x0001d55a; fbreak; };
  'iota;' => { output->first = 0x03b9; fbreak; };
  'iprod;' => { output->first = 0x2a3c; fbreak; };
  'iquest;' => { output->first = 0xbf; fbreak; };
  'iquest' => { output->first = 0xbf; fbreak; };
  'iscr;' => { output->first = 0x0001d4be; fbreak; };
  'isin;' => { output->first = 0x2208; fbreak; };
  'isinE;' => { output->first = 0x22f9; fbreak; };
  'isindot;' => { output->first = 0x22f5; fbreak; };
  'isins;' => { output->first = 0x22f4; fbreak; };
  'isinsv;' => { output->first = 0x22f3; fbreak; };
  'isinv;' => { output->first = 0x2208; fbreak; };
  'it;' => { output->first = 0x2062; fbreak; };
  'itilde;' => { output->first = 0x0129; fbreak; };
  'iukcy;' => { output->first = 0x0456; fbreak; };
  'iuml;' => { output->first = 0xef; fbreak; };
  'iuml' => { output->first = 0xef; fbreak; };
  'jcirc;' => { output->first = 0x0135; fbreak; };
  'jcy;' => { output->first = 0x0439; fbreak; };
  'jfr;' => { output->first = 0x0001d527; fbreak; };
  'jmath;' => { output->first = 0x0237; fbreak; };
  'jopf;' => { output->first = 0x0001d55b; fbreak; };
  'jscr;' => { output->first = 0x0001d4bf; fbreak; };
  'jsercy;' => { output->first = 0x0458; fbreak; };
  'jukcy;' => { output->first = 0x0454; fbreak; };
  'kappa;' => { output->first = 0x03ba; fbreak; };
  'kappav;' => { output->first = 0x03f0; fbreak; };
  'kcedil;' => { output->first = 0x0137; fbreak; };
  'kcy;' => { output->first = 0x043a; fbreak; };
  'kfr;' => { output->first = 0x0001d528; fbreak; };
  'kgreen;' => { output->first = 0x0138; fbreak; };
  'khcy;' => { output->first = 0x0445; fbreak; };
  'kjcy;' => { output->first = 0x045c; fbreak; };
  'kopf;' => { output->first = 0x0001d55c; fbreak; };
  'kscr;' => { output->first = 0x0001d4c0; fbreak; };
  'lAarr;' => { output->first = 0x21da; fbreak; };
  'lArr;' => { output->first = 0x21d0; fbreak; };
  'lAtail;' => { output->first = 0x291b; fbreak; };
  'lBarr;' => { output->first = 0x290e; fbreak; };
  'lE;' => { output->first = 0x2266; fbreak; };
  'lEg;' => { output->first = 0x2a8b; fbreak; };
  'lHar;' => { output->first = 0x2962; fbreak; };
  'lacute;' => { output->first = 0x013a; fbreak; };
  'laemptyv;' => { output->first = 0x29b4; fbreak; };
  'lagran;' => { output->first = 0x2112; fbreak; };
  'lambda;' => { output->first = 0x03bb; fbreak; };
  'lang;' => { output->first = 0x27e8; fbreak; };
  'langd;' => { output->first = 0x2991; fbreak; };
  'langle;' => { output->first = 0x27e8; fbreak; };
  'lap;' => { output->first = 0x2a85; fbreak; };
  'laquo;' => { output->first = 0xab; fbreak; };
  'laquo' => { output->first = 0xab; fbreak; };
  'larr;' => { output->first = 0x2190; fbreak; };
  'larrb;' => { output->first = 0x21e4; fbreak; };
  'larrbfs;' => { output->first = 0x291f; fbreak; };
  'larrfs;' => { output->first = 0x291d; fbreak; };
  'larrhk;' => { output->first = 0x21a9; fbreak; };
  'larrlp;' => { output->first = 0x21ab; fbreak; };
  'larrpl;' => { output->first = 0x2939; fbreak; };
  'larrsim;' => { output->first = 0x2973; fbreak; };
  'larrtl;' => { output->first = 0x21a2; fbreak; };
  'lat;' => { output->first = 0x2aab; fbreak; };
  'latail;' => { output->first = 0x2919; fbreak; };
  'late;' => { output->first = 0x2aad; fbreak; };
  'lates;' => { output->first = 0x2aad; output->second = 0xfe00; fbreak; };
  'lbarr;' => { output->first = 0x290c; fbreak; };
  'lbbrk;' => { output->first = 0x2772; fbreak; };
  'lbrace;' => { output->first = 0x7b; fbreak; };
  'lbrack;' => { output->first = 0x5b; fbreak; };
  'lbrke;' => { output->first = 0x298b; fbreak; };
  'lbrksld;' => { output->first = 0x298f; fbreak; };
  'lbrkslu;' => { output->first = 0x298d; fbreak; };
  'lcaron;' => { output->first = 0x013e; fbreak; };
  'lcedil;' => { output->first = 0x013c; fbreak; };
  'lceil;' => { output->first = 0x2308; fbreak; };
  'lcub;' => { output->first = 0x7b; fbreak; };
  'lcy;' => { output->first = 0x043b; fbreak; };
  'ldca;' => { output->first = 0x2936; fbreak; };
  'ldquo;' => { output->first = 0x201c; fbreak; };
  'ldquor;' => { output->first = 0x201e; fbreak; };
  'ldrdhar;' => { output->first = 0x2967; fbreak; };
  'ldrushar;' => { output->first = 0x294b; fbreak; };
  'ldsh;' => { output->first = 0x21b2; fbreak; };
  'le;' => { output->first = 0x2264; fbreak; };
  'leftarrow;' => { output->first = 0x2190; fbreak; };
  'leftarrowtail;' => { output->first = 0x21a2; fbreak; };
  'leftharpoondown;' => { output->first = 0x21bd; fbreak; };
  'leftharpoonup;' => { output->first = 0x21bc; fbreak; };
  'leftleftarrows;' => { output->first = 0x21c7; fbreak; };
  'leftrightarrow;' => { output->first = 0x2194; fbreak; };
  'leftrightarrows;' => { output->first = 0x21c6; fbreak; };
  'leftrightharpoons;' => { output->first = 0x21cb; fbreak; };
  'leftrightsquigarrow;' => { output->first = 0x21ad; fbreak; };
  'leftthreetimes;' => { output->first = 0x22cb; fbreak; };
  'leg;' => { output->first = 0x22da; fbreak; };
  'leq;' => { output->first = 0x2264; fbreak; };
  'leqq;' => { output->first = 0x2266; fbreak; };
  'leqslant;' => { output->first = 0x2a7d; fbreak; };
  'les;' => { output->first = 0x2a7d; fbreak; };
  'lescc;' => { output->first = 0x2aa8; fbreak; };
  'lesdot;' => { output->first = 0x2a7f; fbreak; };
  'lesdoto;' => { output->first = 0x2a81; fbreak; };
  'lesdotor;' => { output->first = 0x2a83; fbreak; };
  'lesg;' => { output->first = 0x22da; output->second = 0xfe00; fbreak; };
  'lesges;' => { output->first = 0x2a93; fbreak; };
  'lessapprox;' => { output->first = 0x2a85; fbreak; };
  'lessdot;' => { output->first = 0x22d6; fbreak; };
  'lesseqgtr;' => { output->first = 0x22da; fbreak; };
  'lesseqqgtr;' => { output->first = 0x2a8b; fbreak; };
  'lessgtr;' => { output->first = 0x2276; fbreak; };
  'lesssim;' => { output->first = 0x2272; fbreak; };
  'lfisht;' => { output->first = 0x297c; fbreak; };
  'lfloor;' => { output->first = 0x230a; fbreak; };
  'lfr;' => { output->first = 0x0001d529; fbreak; };
  'lg;' => { output->first = 0x2276; fbreak; };
  'lgE;' => { output->first = 0x2a91; fbreak; };
  'lhard;' => { output->first = 0x21bd; fbreak; };
  'lharu;' => { output->first = 0x21bc; fbreak; };
  'lharul;' => { output->first = 0x296a; fbreak; };
  'lhblk;' => { output->first = 0x2584; fbreak; };
  'ljcy;' => { output->first = 0x0459; fbreak; };
  'll;' => { output->first = 0x226a; fbreak; };
  'llarr;' => { output->first = 0x21c7; fbreak; };
  'llcorner;' => { output->first = 0x231e; fbreak; };
  'llhard;' => { output->first = 0x296b; fbreak; };
  'lltri;' => { output->first = 0x25fa; fbreak; };
  'lmidot;' => { output->first = 0x0140; fbreak; };
  'lmoust;' => { output->first = 0x23b0; fbreak; };
  'lmoustache;' => { output->first = 0x23b0; fbreak; };
  'lnE;' => { output->first = 0x2268; fbreak; };
  'lnap;' => { output->first = 0x2a89; fbreak; };
  'lnapprox;' => { output->first = 0x2a89; fbreak; };
  'lne;' => { output->first = 0x2a87; fbreak; };
  'lneq;' => { output->first = 0x2a87; fbreak; };
  'lneqq;' => { output->first = 0x2268; fbreak; };
  'lnsim;' => { output->first = 0x22e6; fbreak; };
  'loang;' => { output->first = 0x27ec; fbreak; };
  'loarr;' => { output->first = 0x21fd; fbreak; };
  'lobrk;' => { output->first = 0x27e6; fbreak; };
  'longleftarrow;' => { output->first = 0x27f5; fbreak; };
  'longleftrightarrow;' => { output->first = 0x27f7; fbreak; };
  'longmapsto;' => { output->first = 0x27fc; fbreak; };
  'longrightarrow;' => { output->first = 0x27f6; fbreak; };
  'looparrowleft;' => { output->first = 0x21ab; fbreak; };
  'looparrowright;' => { output->first = 0x21ac; fbreak; };
  'lopar;' => { output->first = 0x2985; fbreak; };
  'lopf;' => { output->first = 0x0001d55d; fbreak; };
  'loplus;' => { output->first = 0x2a2d; fbreak; };
  'lotimes;' => { output->first = 0x2a34; fbreak; };
  'lowast;' => { output->first = 0x2217; fbreak; };
  'lowbar;' => { output->first = 0x5f; fbreak; };
  'loz;' => { output->first = 0x25ca; fbreak; };
  'lozenge;' => { output->first = 0x25ca; fbreak; };
  'lozf;' => { output->first = 0x29eb; fbreak; };
  'lpar;' => { output->first = 0x28; fbreak; };
  'lparlt;' => { output->first = 0x2993; fbreak; };
  'lrarr;' => { output->first = 0x21c6; fbreak; };
  'lrcorner;' => { output->first = 0x231f; fbreak; };
  'lrhar;' => { output->first = 0x21cb; fbreak; };
  'lrhard;' => { output->first = 0x296d; fbreak; };
  'lrm;' => { output->first = 0x200e; fbreak; };
  'lrtri;' => { output->first = 0x22bf; fbreak; };
  'lsaquo;' => { output->first = 0x2039; fbreak; };
  'lscr;' => { output->first = 0x0001d4c1; fbreak; };
  'lsh;' => { output->first = 0x21b0; fbreak; };
  'lsim;' => { output->first = 0x2272; fbreak; };
  'lsime;' => { output->first = 0x2a8d; fbreak; };
  'lsimg;' => { output->first = 0x2a8f; fbreak; };
  'lsqb;' => { output->first = 0x5b; fbreak; };
  'lsquo;' => { output->first = 0x2018; fbreak; };
  'lsquor;' => { output->first = 0x201a; fbreak; };
  'lstrok;' => { output->first = 0x0142; fbreak; };
  'lt;' => { output->first = 0x3c; fbreak; };
  'lt' => { output->first = 0x3c; fbreak; };
  'ltcc;' => { output->first = 0x2aa6; fbreak; };
  'ltcir;' => { output->first = 0x2a79; fbreak; };
  'ltdot;' => { output->first = 0x22d6; fbreak; };
  'lthree;' => { output->first = 0x22cb; fbreak; };
  'ltimes;' => { output->first = 0x22c9; fbreak; };
  'ltlarr;' => { output->first = 0x2976; fbreak; };
  'ltquest;' => { output->first = 0x2a7b; fbreak; };
  'ltrPar;' => { output->first = 0x2996; fbreak; };
  'ltri;' => { output->first = 0x25c3; fbreak; };
  'ltrie;' => { output->first = 0x22b4; fbreak; };
  'ltrif;' => { output->first = 0x25c2; fbreak; };
  'lurdshar;' => { output->first = 0x294a; fbreak; };
  'luruhar;' => { output->first = 0x2966; fbreak; };
  'lvertneqq;' => { output->first = 0x2268; output->second = 0xfe00; fbreak; };
  'lvnE;' => { output->first = 0x2268; output->second = 0xfe00; fbreak; };
  'mDDot;' => { output->first = 0x223a; fbreak; };
  'macr;' => { output->first = 0xaf; fbreak; };
  'macr' => { output->first = 0xaf; fbreak; };
  'male;' => { output->first = 0x2642; fbreak; };
  'malt;' => { output->first = 0x2720; fbreak; };
  'maltese;' => { output->first = 0x2720; fbreak; };
  'map;' => { output->first = 0x21a6; fbreak; };
  'mapsto;' => { output->first = 0x21a6; fbreak; };
  'mapstodown;' => { output->first = 0x21a7; fbreak; };
  'mapstoleft;' => { output->first = 0x21a4; fbreak; };
  'mapstoup;' => { output->first = 0x21a5; fbreak; };
  'marker;' => { output->first = 0x25ae; fbreak; };
  'mcomma;' => { output->first = 0x2a29; fbreak; };
  'mcy;' => { output->first = 0x043c; fbreak; };
  'mdash;' => { output->first = 0x2014; fbreak; };
  'measuredangle;' => { output->first = 0x2221; fbreak; };
  'mfr;' => { output->first = 0x0001d52a; fbreak; };
  'mho;' => { output->first = 0x2127; fbreak; };
  'micro;' => { output->first = 0xb5; fbreak; };
  'micro' => { output->first = 0xb5; fbreak; };
  'mid;' => { output->first = 0x2223; fbreak; };
  'midast;' => { output->first = 0x2a; fbreak; };
  'midcir;' => { output->first = 0x2af0; fbreak; };
  'middot;' => { output->first = 0xb7; fbreak; };
  'middot' => { output->first = 0xb7; fbreak; };
  'minus;' => { output->first = 0x2212; fbreak; };
  'minusb;' => { output->first = 0x229f; fbreak; };
  'minusd;' => { output->first = 0x2238; fbreak; };
  'minusdu;' => { output->first = 0x2a2a; fbreak; };
  'mlcp;' => { output->first = 0x2adb; fbreak; };
  'mldr;' => { output->first = 0x2026; fbreak; };
  'mnplus;' => { output->first = 0x2213; fbreak; };
  'models;' => { output->first = 0x22a7; fbreak; };
  'mopf;' => { output->first = 0x0001d55e; fbreak; };
  'mp;' => { output->first = 0x2213; fbreak; };
  'mscr;' => { output->first = 0x0001d4c2; fbreak; };
  'mstpos;' => { output->first = 0x223e; fbreak; };
  'mu;' => { output->first = 0x03bc; fbreak; };
  'multimap;' => { output->first = 0x22b8; fbreak; };
  'mumap;' => { output->first = 0x22b8; fbreak; };
  'nGg;' => { output->first = 0x22d9; output->second = 0x0338; fbreak; };
  'nGt;' => { output->first = 0x226b; output->second = 0x20d2; fbreak; };
  'nGtv;' => { output->first = 0x226b; output->second = 0x0338; fbreak; };
  'nLeftarrow;' => { output->first = 0x21cd; fbreak; };
  'nLeftrightarrow;' => { output->first = 0x21ce; fbreak; };
  'nLl;' => { output->first = 0x22d8; output->second = 0x0338; fbreak; };
  'nLt;' => { output->first = 0x226a; output->second = 0x20d2; fbreak; };
  'nLtv;' => { output->first = 0x226a; output->second = 0x0338; fbreak; };
  'nRightarrow;' => { output->first = 0x21cf; fbreak; };
  'nVDash;' => { output->first = 0x22af; fbreak; };
  'nVdash;' => { output->first = 0x22ae; fbreak; };
  'nabla;' => { output->first = 0x2207; fbreak; };
  'nacute;' => { output->first = 0x0144; fbreak; };
  'nang;' => { output->first = 0x2220; output->second = 0x20d2; fbreak; };
  'nap;' => { output->first = 0x2249; fbreak; };
  'napE;' => { output->first = 0x2a70; output->second = 0x0338; fbreak; };
  'napid;' => { output->first = 0x224b; output->second = 0x0338; fbreak; };
  'napos;' => { output->first = 0x0149; fbreak; };
  'napprox;' => { output->first = 0x2249; fbreak; };
  'natur;' => { output->first = 0x266e; fbreak; };
  'natural;' => { output->first = 0x266e; fbreak; };
  'naturals;' => { output->first = 0x2115; fbreak; };
  'nbsp;' => { output->first = 0xa0; fbreak; };
  'nbsp' => { output->first = 0xa0; fbreak; };
  'nbump;' => { output->first = 0x224e; output->second = 0x0338; fbreak; };
  'nbumpe;' => { output->first = 0x224f; output->second = 0x0338; fbreak; };
  'ncap;' => { output->first = 0x2a43; fbreak; };
  'ncaron;' => { output->first = 0x0148; fbreak; };
  'ncedil;' => { output->first = 0x0146; fbreak; };
  'ncong;' => { output->first = 0x2247; fbreak; };
  'ncongdot;' => { output->first = 0x2a6d; output->second = 0x0338; fbreak; };
  'ncup;' => { output->first = 0x2a42; fbreak; };
  'ncy;' => { output->first = 0x043d; fbreak; };
  'ndash;' => { output->first = 0x2013; fbreak; };
  'ne;' => { output->first = 0x2260; fbreak; };
  'neArr;' => { output->first = 0x21d7; fbreak; };
  'nearhk;' => { output->first = 0x2924; fbreak; };
  'nearr;' => { output->first = 0x2197; fbreak; };
  'nearrow;' => { output->first = 0x2197; fbreak; };
  'nedot;' => { output->first = 0x2250; output->second = 0x0338; fbreak; };
  'nequiv;' => { output->first = 0x2262; fbreak; };
  'nesear;' => { output->first = 0x2928; fbreak; };
  'nesim;' => { output->first = 0x2242; output->second = 0x0338; fbreak; };
  'nexist;' => { output->first = 0x2204; fbreak; };
  'nexists;' => { output->first = 0x2204; fbreak; };
  'nfr;' => { output->first = 0x0001d52b; fbreak; };
  'ngE;' => { output->first = 0x2267; output->second = 0x0338; fbreak; };
  'nge;' => { output->first = 0x2271; fbreak; };
  'ngeq;' => { output->first = 0x2271; fbreak; };
  'ngeqq;' => { output->first = 0x2267; output->second = 0x0338; fbreak; };
  'ngeqslant;' => { output->first = 0x2a7e; output->second = 0x0338; fbreak; };
  'nges;' => { output->first = 0x2a7e; output->second = 0x0338; fbreak; };
  'ngsim;' => { output->first = 0x2275; fbreak; };
  'ngt;' => { output->first = 0x226f; fbreak; };
  'ngtr;' => { output->first = 0x226f; fbreak; };
  'nhArr;' => { output->first = 0x21ce; fbreak; };
  'nharr;' => { output->first = 0x21ae; fbreak; };
  'nhpar;' => { output->first = 0x2af2; fbreak; };
  'ni;' => { output->first = 0x220b; fbreak; };
  'nis;' => { output->first = 0x22fc; fbreak; };
  'nisd;' => { output->first = 0x22fa; fbreak; };
  'niv;' => { output->first = 0x220b; fbreak; };
  'njcy;' => { output->first = 0x045a; fbreak; };
  'nlArr;' => { output->first = 0x21cd; fbreak; };
  'nlE;' => { output->first = 0x2266; output->second = 0x0338; fbreak; };
  'nlarr;' => { output->first = 0x219a; fbreak; };
  'nldr;' => { output->first = 0x2025; fbreak; };
  'nle;' => { output->first = 0x2270; fbreak; };
  'nleftarrow;' => { output->first = 0x219a; fbreak; };
  'nleftrightarrow;' => { output->first = 0x21ae; fbreak; };
  'nleq;' => { output->first = 0x2270; fbreak; };
  'nleqq;' => { output->first = 0x2266; output->second = 0x0338; fbreak; };
  'nleqslant;' => { output->first = 0x2a7d; output->second = 0x0338; fbreak; };
  'nles;' => { output->first = 0x2a7d; output->second = 0x0338; fbreak; };
  'nless;' => { output->first = 0x226e; fbreak; };
  'nlsim;' => { output->first = 0x2274; fbreak; };
  'nlt;' => { output->first = 0x226e; fbreak; };
  'nltri;' => { output->first = 0x22ea; fbreak; };
  'nltrie;' => { output->first = 0x22ec; fbreak; };
  'nmid;' => { output->first = 0x2224; fbreak; };
  'nopf;' => { output->first = 0x0001d55f; fbreak; };
  'not;' => { output->first = 0xac; fbreak; };
  'notin;' => { output->first = 0x2209; fbreak; };
  'notinE;' => { output->first = 0x22f9; output->second = 0x0338; fbreak; };
  'notindot;' => { output->first = 0x22f5; output->second = 0x0338; fbreak; };
  'notinva;' => { output->first = 0x2209; fbreak; };
  'notinvb;' => { output->first = 0x22f7; fbreak; };
  'notinvc;' => { output->first = 0x22f6; fbreak; };
  'notni;' => { output->first = 0x220c; fbreak; };
  'notniva;' => { output->first = 0x220c; fbreak; };
  'notnivb;' => { output->first = 0x22fe; fbreak; };
  'notnivc;' => { output->first = 0x22fd; fbreak; };
  'not' => { output->first = 0xac; fbreak; };
  'npar;' => { output->first = 0x2226; fbreak; };
  'nparallel;' => { output->first = 0x2226; fbreak; };
  'nparsl;' => { output->first = 0x2afd; output->second = 0x20e5; fbreak; };
  'npart;' => { output->first = 0x2202; output->second = 0x0338; fbreak; };
  'npolint;' => { output->first = 0x2a14; fbreak; };
  'npr;' => { output->first = 0x2280; fbreak; };
  'nprcue;' => { output->first = 0x22e0; fbreak; };
  'npre;' => { output->first = 0x2aaf; output->second = 0x0338; fbreak; };
  'nprec;' => { output->first = 0x2280; fbreak; };
  'npreceq;' => { output->first = 0x2aaf; output->second = 0x0338; fbreak; };
  'nrArr;' => { output->first = 0x21cf; fbreak; };
  'nrarr;' => { output->first = 0x219b; fbreak; };
  'nrarrc;' => { output->first = 0x2933; output->second = 0x0338; fbreak; };
  'nrarrw;' => { output->first = 0x219d; output->second = 0x0338; fbreak; };
  'nrightarrow;' => { output->first = 0x219b; fbreak; };
  'nrtri;' => { output->first = 0x22eb; fbreak; };
  'nrtrie;' => { output->first = 0x22ed; fbreak; };
  'nsc;' => { output->first = 0x2281; fbreak; };
  'nsccue;' => { output->first = 0x22e1; fbreak; };
  'nsce;' => { output->first = 0x2ab0; output->second = 0x0338; fbreak; };
  'nscr;' => { output->first = 0x0001d4c3; fbreak; };
  'nshortmid;' => { output->first = 0x2224; fbreak; };
  'nshortparallel;' => { output->first = 0x2226; fbreak; };
  'nsim;' => { output->first = 0x2241; fbreak; };
  'nsime;' => { output->first = 0x2244; fbreak; };
  'nsimeq;' => { output->first = 0x2244; fbreak; };
  'nsmid;' => { output->first = 0x2224; fbreak; };
  'nspar;' => { output->first = 0x2226; fbreak; };
  'nsqsube;' => { output->first = 0x22e2; fbreak; };
  'nsqsupe;' => { output->first = 0x22e3; fbreak; };
  'nsub;' => { output->first = 0x2284; fbreak; };
  'nsubE;' => { output->first = 0x2ac5; output->second = 0x0338; fbreak; };
  'nsube;' => { output->first = 0x2288; fbreak; };
  'nsubset;' => { output->first = 0x2282; output->second = 0x20d2; fbreak; };
  'nsubseteq;' => { output->first = 0x2288; fbreak; };
  'nsubseteqq;' => { output->first = 0x2ac5; output->second = 0x0338; fbreak; };
  'nsucc;' => { output->first = 0x2281; fbreak; };
  'nsucceq;' => { output->first = 0x2ab0; output->second = 0x0338; fbreak; };
  'nsup;' => { output->first = 0x2285; fbreak; };
  'nsupE;' => { output->first = 0x2ac6; output->second = 0x0338; fbreak; };
  'nsupe;' => { output->first = 0x2289; fbreak; };
  'nsupset;' => { output->first = 0x2283; output->second = 0x20d2; fbreak; };
  'nsupseteq;' => { output->first = 0x2289; fbreak; };
  'nsupseteqq;' => { output->first = 0x2ac6; output->second = 0x0338; fbreak; };
  'ntgl;' => { output->first = 0x2279; fbreak; };
  'ntilde;' => { output->first = 0xf1; fbreak; };
  'ntilde' => { output->first = 0xf1; fbreak; };
  'ntlg;' => { output->first = 0x2278; fbreak; };
  'ntriangleleft;' => { output->first = 0x22ea; fbreak; };
  'ntrianglelefteq;' => { output->first = 0x22ec; fbreak; };
  'ntriangleright;' => { output->first = 0x22eb; fbreak; };
  'ntrianglerighteq;' => { output->first = 0x22ed; fbreak; };
  'nu;' => { output->first = 0x03bd; fbreak; };
  'num;' => { output->first = 0x23; fbreak; };
  'numero;' => { output->first = 0x2116; fbreak; };
  'numsp;' => { output->first = 0x2007; fbreak; };
  'nvDash;' => { output->first = 0x22ad; fbreak; };
  'nvHarr;' => { output->first = 0x2904; fbreak; };
  'nvap;' => { output->first = 0x224d; output->second = 0x20d2; fbreak; };
  'nvdash;' => { output->first = 0x22ac; fbreak; };
  'nvge;' => { output->first = 0x2265; output->second = 0x20d2; fbreak; };
  'nvgt;' => { output->first = 0x3e; output->second = 0x20d2; fbreak; };
  'nvinfin;' => { output->first = 0x29de; fbreak; };
  'nvlArr;' => { output->first = 0x2902; fbreak; };
  'nvle;' => { output->first = 0x2264; output->second = 0x20d2; fbreak; };
  'nvlt;' => { output->first = 0x3c; output->second = 0x20d2; fbreak; };
  'nvltrie;' => { output->first = 0x22b4; output->second = 0x20d2; fbreak; };
  'nvrArr;' => { output->first = 0x2903; fbreak; };
  'nvrtrie;' => { output->first = 0x22b5; output->second = 0x20d2; fbreak; };
  'nvsim;' => { output->first = 0x223c; output->second = 0x20d2; fbreak; };
  'nwArr;' => { output->first = 0x21d6; fbreak; };
  'nwarhk;' => { output->first = 0x2923; fbreak; };
  'nwarr;' => { output->first = 0x2196; fbreak; };
  'nwarrow;' => { output->first = 0x2196; fbreak; };
  'nwnear;' => { output->first = 0x2927; fbreak; };
  'oS;' => { output->first = 0x24c8; fbreak; };
  'oacute;' => { output->first = 0xf3; fbreak; };
  'oacute' => { output->first = 0xf3; fbreak; };
  'oast;' => { output->first = 0x229b; fbreak; };
  'ocir;' => { output->first = 0x229a; fbreak; };
  'ocirc;' => { output->first = 0xf4; fbreak; };
  'ocirc' => { output->first = 0xf4; fbreak; };
  'ocy;' => { output->first = 0x043e; fbreak; };
  'odash;' => { output->first = 0x229d; fbreak; };
  'odblac;' => { output->first = 0x0151; fbreak; };
  'odiv;' => { output->first = 0x2a38; fbreak; };
  'odot;' => { output->first = 0x2299; fbreak; };
  'odsold;' => { output->first = 0x29bc; fbreak; };
  'oelig;' => { output->first = 0x0153; fbreak; };
  'ofcir;' => { output->first = 0x29bf; fbreak; };
  'ofr;' => { output->first = 0x0001d52c; fbreak; };
  'ogon;' => { output->first = 0x02db; fbreak; };
  'ograve;' => { output->first = 0xf2; fbreak; };
  'ograve' => { output->first = 0xf2; fbreak; };
  'ogt;' => { output->first = 0x29c1; fbreak; };
  'ohbar;' => { output->first = 0x29b5; fbreak; };
  'ohm;' => { output->first = 0x03a9; fbreak; };
  'oint;' => { output->first = 0x222e; fbreak; };
  'olarr;' => { output->first = 0x21ba; fbreak; };
  'olcir;' => { output->first = 0x29be; fbreak; };
  'olcross;' => { output->first = 0x29bb; fbreak; };
  'oline;' => { output->first = 0x203e; fbreak; };
  'olt;' => { output->first = 0x29c0; fbreak; };
  'omacr;' => { output->first = 0x014d; fbreak; };
  'omega;' => { output->first = 0x03c9; fbreak; };
  'omicron;' => { output->first = 0x03bf; fbreak; };
  'omid;' => { output->first = 0x29b6; fbreak; };
  'ominus;' => { output->first = 0x2296; fbreak; };
  'oopf;' => { output->first = 0x0001d560; fbreak; };
  'opar;' => { output->first = 0x29b7; fbreak; };
  'operp;' => { output->first = 0x29b9; fbreak; };
  'oplus;' => { output->first = 0x2295; fbreak; };
  'or;' => { output->first = 0x2228; fbreak; };
  'orarr;' => { output->first = 0x21bb; fbreak; };
  'ord;' => { output->first = 0x2a5d; fbreak; };
  'order;' => { output->first = 0x2134; fbreak; };
  'orderof;' => { output->first = 0x2134; fbreak; };
  'ordf;' => { output->first = 0xaa; fbreak; };
  'ordf' => { output->first = 0xaa; fbreak; };
  'ordm;' => { output->first = 0xba; fbreak; };
  'ordm' => { output->first = 0xba; fbreak; };
  'origof;' => { output->first = 0x22b6; fbreak; };
  'oror;' => { output->first = 0x2a56; fbreak; };
  'orslope;' => { output->first = 0x2a57; fbreak; };
  'orv;' => { output->first = 0x2a5b; fbreak; };
  'oscr;' => { output->first = 0x2134; fbreak; };
  'oslash;' => { output->first = 0xf8; fbreak; };
  'oslash' => { output->first = 0xf8; fbreak; };
  'osol;' => { output->first = 0x2298; fbreak; };
  'otilde;' => { output->first = 0xf5; fbreak; };
  'otilde' => { output->first = 0xf5; fbreak; };
  'otimes;' => { output->first = 0x2297; fbreak; };
  'otimesas;' => { output->first = 0x2a36; fbreak; };
  'ouml;' => { output->first = 0xf6; fbreak; };
  'ouml' => { output->first = 0xf6; fbreak; };
  'ovbar;' => { output->first = 0x233d; fbreak; };
  'par;' => { output->first = 0x2225; fbreak; };
  'para;' => { output->first = 0xb6; fbreak; };
  'para' => { output->first = 0xb6; fbreak; };
  'parallel;' => { output->first = 0x2225; fbreak; };
  'parsim;' => { output->first = 0x2af3; fbreak; };
  'parsl;' => { output->first = 0x2afd; fbreak; };
  'part;' => { output->first = 0x2202; fbreak; };
  'pcy;' => { output->first = 0x043f; fbreak; };
  'percnt;' => { output->first = 0x25; fbreak; };
  'period;' => { output->first = 0x2e; fbreak; };
  'permil;' => { output->first = 0x2030; fbreak; };
  'perp;' => { output->first = 0x22a5; fbreak; };
  'pertenk;' => { output->first = 0x2031; fbreak; };
  'pfr;' => { output->first = 0x0001d52d; fbreak; };
  'phi;' => { output->first = 0x03c6; fbreak; };
  'phiv;' => { output->first = 0x03d5; fbreak; };
  'phmmat;' => { output->first = 0x2133; fbreak; };
  'phone;' => { output->first = 0x260e; fbreak; };
  'pi;' => { output->first = 0x03c0; fbreak; };
  'pitchfork;' => { output->first = 0x22d4; fbreak; };
  'piv;' => { output->first = 0x03d6; fbreak; };
  'planck;' => { output->first = 0x210f; fbreak; };
  'planckh;' => { output->first = 0x210e; fbreak; };
  'plankv;' => { output->first = 0x210f; fbreak; };
  'plus;' => { output->first = 0x2b; fbreak; };
  'plusacir;' => { output->first = 0x2a23; fbreak; };
  'plusb;' => { output->first = 0x229e; fbreak; };
  'pluscir;' => { output->first = 0x2a22; fbreak; };
  'plusdo;' => { output->first = 0x2214; fbreak; };
  'plusdu;' => { output->first = 0x2a25; fbreak; };
  'pluse;' => { output->first = 0x2a72; fbreak; };
  'plusmn;' => { output->first = 0xb1; fbreak; };
  'plusmn' => { output->first = 0xb1; fbreak; };
  'plussim;' => { output->first = 0x2a26; fbreak; };
  'plustwo;' => { output->first = 0x2a27; fbreak; };
  'pm;' => { output->first = 0xb1; fbreak; };
  'pointint;' => { output->first = 0x2a15; fbreak; };
  'popf;' => { output->first = 0x0001d561; fbreak; };
  'pound;' => { output->first = 0xa3; fbreak; };
  'pound' => { output->first = 0xa3; fbreak; };
  'pr;' => { output->first = 0x227a; fbreak; };
  'prE;' => { output->first = 0x2ab3; fbreak; };
  'prap;' => { output->first = 0x2ab7; fbreak; };
  'prcue;' => { output->first = 0x227c; fbreak; };
  'pre;' => { output->first = 0x2aaf; fbreak; };
  'prec;' => { output->first = 0x227a; fbreak; };
  'precapprox;' => { output->first = 0x2ab7; fbreak; };
  'preccurlyeq;' => { output->first = 0x227c; fbreak; };
  'preceq;' => { output->first = 0x2aaf; fbreak; };
  'precnapprox;' => { output->first = 0x2ab9; fbreak; };
  'precneqq;' => { output->first = 0x2ab5; fbreak; };
  'precnsim;' => { output->first = 0x22e8; fbreak; };
  'precsim;' => { output->first = 0x227e; fbreak; };
  'prime;' => { output->first = 0x2032; fbreak; };
  'primes;' => { output->first = 0x2119; fbreak; };
  'prnE;' => { output->first = 0x2ab5; fbreak; };
  'prnap;' => { output->first = 0x2ab9; fbreak; };
  'prnsim;' => { output->first = 0x22e8; fbreak; };
  'prod;' => { output->first = 0x220f; fbreak; };
  'profalar;' => { output->first = 0x232e; fbreak; };
  'profline;' => { output->first = 0x2312; fbreak; };
  'profsurf;' => { output->first = 0x2313; fbreak; };
  'prop;' => { output->first = 0x221d; fbreak; };
  'propto;' => { output->first = 0x221d; fbreak; };
  'prsim;' => { output->first = 0x227e; fbreak; };
  'prurel;' => { output->first = 0x22b0; fbreak; };
  'pscr;' => { output->first = 0x0001d4c5; fbreak; };
  'psi;' => { output->first = 0x03c8; fbreak; };
  'puncsp;' => { output->first = 0x2008; fbreak; };
  'qfr;' => { output->first = 0x0001d52e; fbreak; };
  'qint;' => { output->first = 0x2a0c; fbreak; };
  'qopf;' => { output->first = 0x0001d562; fbreak; };
  'qprime;' => { output->first = 0x2057; fbreak; };
  'qscr;' => { output->first = 0x0001d4c6; fbreak; };
  'quaternions;' => { output->first = 0x210d; fbreak; };
  'quatint;' => { output->first = 0x2a16; fbreak; };
  'quest;' => { output->first = 0x3f; fbreak; };
  'questeq;' => { output->first = 0x225f; fbreak; };
  'quot;' => { output->first = 0x22; fbreak; };
  'quot' => { output->first = 0x22; fbreak; };
  'rAarr;' => { output->first = 0x21db; fbreak; };
  'rArr;' => { output->first = 0x21d2; fbreak; };
  'rAtail;' => { output->first = 0x291c; fbreak; };
  'rBarr;' => { output->first = 0x290f; fbreak; };
  'rHar;' => { output->first = 0x2964; fbreak; };
  'race;' => { output->first = 0x223d; output->second = 0x0331; fbreak; };
  'racute;' => { output->first = 0x0155; fbreak; };
  'radic;' => { output->first = 0x221a; fbreak; };
  'raemptyv;' => { output->first = 0x29b3; fbreak; };
  'rang;' => { output->first = 0x27e9; fbreak; };
  'rangd;' => { output->first = 0x2992; fbreak; };
  'range;' => { output->first = 0x29a5; fbreak; };
  'rangle;' => { output->first = 0x27e9; fbreak; };
  'raquo;' => { output->first = 0xbb; fbreak; };
  'raquo' => { output->first = 0xbb; fbreak; };
  'rarr;' => { output->first = 0x2192; fbreak; };
  'rarrap;' => { output->first = 0x2975; fbreak; };
  'rarrb;' => { output->first = 0x21e5; fbreak; };
  'rarrbfs;' => { output->first = 0x2920; fbreak; };
  'rarrc;' => { output->first = 0x2933; fbreak; };
  'rarrfs;' => { output->first = 0x291e; fbreak; };
  'rarrhk;' => { output->first = 0x21aa; fbreak; };
  'rarrlp;' => { output->first = 0x21ac; fbreak; };
  'rarrpl;' => { output->first = 0x2945; fbreak; };
  'rarrsim;' => { output->first = 0x2974; fbreak; };
  'rarrtl;' => { output->first = 0x21a3; fbreak; };
  'rarrw;' => { output->first = 0x219d; fbreak; };
  'ratail;' => { output->first = 0x291a; fbreak; };
  'ratio;' => { output->first = 0x2236; fbreak; };
  'rationals;' => { output->first = 0x211a; fbreak; };
  'rbarr;' => { output->first = 0x290d; fbreak; };
  'rbbrk;' => { output->first = 0x2773; fbreak; };
  'rbrace;' => { output->first = 0x7d; fbreak; };
  'rbrack;' => { output->first = 0x5d; fbreak; };
  'rbrke;' => { output->first = 0x298c; fbreak; };
  'rbrksld;' => { output->first = 0x298e; fbreak; };
  'rbrkslu;' => { output->first = 0x2990; fbreak; };
  'rcaron;' => { output->first = 0x0159; fbreak; };
  'rcedil;' => { output->first = 0x0157; fbreak; };
  'rceil;' => { output->first = 0x2309; fbreak; };
  'rcub;' => { output->first = 0x7d; fbreak; };
  'rcy;' => { output->first = 0x0440; fbreak; };
  'rdca;' => { output->first = 0x2937; fbreak; };
  'rdldhar;' => { output->first = 0x2969; fbreak; };
  'rdquo;' => { output->first = 0x201d; fbreak; };
  'rdquor;' => { output->first = 0x201d; fbreak; };
  'rdsh;' => { output->first = 0x21b3; fbreak; };
  'real;' => { output->first = 0x211c; fbreak; };
  'realine;' => { output->first = 0x211b; fbreak; };
  'realpart;' => { output->first = 0x211c; fbreak; };
  'reals;' => { output->first = 0x211d; fbreak; };
  'rect;' => { output->first = 0x25ad; fbreak; };
  'reg;' => { output->first = 0xae; fbreak; };
  'reg' => { output->first = 0xae; fbreak; };
  'rfisht;' => { output->first = 0x297d; fbreak; };
  'rfloor;' => { output->first = 0x230b; fbreak; };
  'rfr;' => { output->first = 0x0001d52f; fbreak; };
  'rhard;' => { output->first = 0x21c1; fbreak; };
  'rharu;' => { output->first = 0x21c0; fbreak; };
  'rharul;' => { output->first = 0x296c; fbreak; };
  'rho;' => { output->first = 0x03c1; fbreak; };
  'rhov;' => { output->first = 0x03f1; fbreak; };
  'rightarrow;' => { output->first = 0x2192; fbreak; };
  'rightarrowtail;' => { output->first = 0x21a3; fbreak; };
  'rightharpoondown;' => { output->first = 0x21c1; fbreak; };
  'rightharpoonup;' => { output->first = 0x21c0; fbreak; };
  'rightleftarrows;' => { output->first = 0x21c4; fbreak; };
  'rightleftharpoons;' => { output->first = 0x21cc; fbreak; };
  'rightrightarrows;' => { output->first = 0x21c9; fbreak; };
  'rightsquigarrow;' => { output->first = 0x219d; fbreak; };
  'rightthreetimes;' => { output->first = 0x22cc; fbreak; };
  'ring;' => { output->first = 0x02da; fbreak; };
  'risingdotseq;' => { output->first = 0x2253; fbreak; };
  'rlarr;' => { output->first = 0x21c4; fbreak; };
  'rlhar;' => { output->first = 0x21cc; fbreak; };
  'rlm;' => { output->first = 0x200f; fbreak; };
  'rmoust;' => { output->first = 0x23b1; fbreak; };
  'rmoustache;' => { output->first = 0x23b1; fbreak; };
  'rnmid;' => { output->first = 0x2aee; fbreak; };
  'roang;' => { output->first = 0x27ed; fbreak; };
  'roarr;' => { output->first = 0x21fe; fbreak; };
  'robrk;' => { output->first = 0x27e7; fbreak; };
  'ropar;' => { output->first = 0x2986; fbreak; };
  'ropf;' => { output->first = 0x0001d563; fbreak; };
  'roplus;' => { output->first = 0x2a2e; fbreak; };
  'rotimes;' => { output->first = 0x2a35; fbreak; };
  'rpar;' => { output->first = 0x29; fbreak; };
  'rpargt;' => { output->first = 0x2994; fbreak; };
  'rppolint;' => { output->first = 0x2a12; fbreak; };
  'rrarr;' => { output->first = 0x21c9; fbreak; };
  'rsaquo;' => { output->first = 0x203a; fbreak; };
  'rscr;' => { output->first = 0x0001d4c7; fbreak; };
  'rsh;' => { output->first = 0x21b1; fbreak; };
  'rsqb;' => { output->first = 0x5d; fbreak; };
  'rsquo;' => { output->first = 0x2019; fbreak; };
  'rsquor;' => { output->first = 0x2019; fbreak; };
  'rthree;' => { output->first = 0x22cc; fbreak; };
  'rtimes;' => { output->first = 0x22ca; fbreak; };
  'rtri;' => { output->first = 0x25b9; fbreak; };
  'rtrie;' => { output->first = 0x22b5; fbreak; };
  'rtrif;' => { output->first = 0x25b8; fbreak; };
  'rtriltri;' => { output->first = 0x29ce; fbreak; };
  'ruluhar;' => { output->first = 0x2968; fbreak; };
  'rx;' => { output->first = 0x211e; fbreak; };
  'sacute;' => { output->first = 0x015b; fbreak; };
  'sbquo;' => { output->first = 0x201a; fbreak; };
  'sc;' => { output->first = 0x227b; fbreak; };
  'scE;' => { output->first = 0x2ab4; fbreak; };
  'scap;' => { output->first = 0x2ab8; fbreak; };
  'scaron;' => { output->first = 0x0161; fbreak; };
  'sccue;' => { output->first = 0x227d; fbreak; };
  'sce;' => { output->first = 0x2ab0; fbreak; };
  'scedil;' => { output->first = 0x015f; fbreak; };
  'scirc;' => { output->first = 0x015d; fbreak; };
  'scnE;' => { output->first = 0x2ab6; fbreak; };
  'scnap;' => { output->first = 0x2aba; fbreak; };
  'scnsim;' => { output->first = 0x22e9; fbreak; };
  'scpolint;' => { output->first = 0x2a13; fbreak; };
  'scsim;' => { output->first = 0x227f; fbreak; };
  'scy;' => { output->first = 0x0441; fbreak; };
  'sdot;' => { output->first = 0x22c5; fbreak; };
  'sdotb;' => { output->first = 0x22a1; fbreak; };
  'sdote;' => { output->first = 0x2a66; fbreak; };
  'seArr;' => { output->first = 0x21d8; fbreak; };
  'searhk;' => { output->first = 0x2925; fbreak; };
  'searr;' => { output->first = 0x2198; fbreak; };
  'searrow;' => { output->first = 0x2198; fbreak; };
  'sect;' => { output->first = 0xa7; fbreak; };
  'sect' => { output->first = 0xa7; fbreak; };
  'semi;' => { output->first = 0x3b; fbreak; };
  'seswar;' => { output->first = 0x2929; fbreak; };
  'setminus;' => { output->first = 0x2216; fbreak; };
  'setmn;' => { output->first = 0x2216; fbreak; };
  'sext;' => { output->first = 0x2736; fbreak; };
  'sfr;' => { output->first = 0x0001d530; fbreak; };
  'sfrown;' => { output->first = 0x2322; fbreak; };
  'sharp;' => { output->first = 0x266f; fbreak; };
  'shchcy;' => { output->first = 0x0449; fbreak; };
  'shcy;' => { output->first = 0x0448; fbreak; };
  'shortmid;' => { output->first = 0x2223; fbreak; };
  'shortparallel;' => { output->first = 0x2225; fbreak; };
  'shy;' => { output->first = 0xad; fbreak; };
  'shy' => { output->first = 0xad; fbreak; };
  'sigma;' => { output->first = 0x03c3; fbreak; };
  'sigmaf;' => { output->first = 0x03c2; fbreak; };
  'sigmav;' => { output->first = 0x03c2; fbreak; };
  'sim;' => { output->first = 0x223c; fbreak; };
  'simdot;' => { output->first = 0x2a6a; fbreak; };
  'sime;' => { output->first = 0x2243; fbreak; };
  'simeq;' => { output->first = 0x2243; fbreak; };
  'simg;' => { output->first = 0x2a9e; fbreak; };
  'simgE;' => { output->first = 0x2aa0; fbreak; };
  'siml;' => { output->first = 0x2a9d; fbreak; };
  'simlE;' => { output->first = 0x2a9f; fbreak; };
  'simne;' => { output->first = 0x2246; fbreak; };
  'simplus;' => { output->first = 0x2a24; fbreak; };
  'simrarr;' => { output->first = 0x2972; fbreak; };
  'slarr;' => { output->first = 0x2190; fbreak; };
  'smallsetminus;' => { output->first = 0x2216; fbreak; };
  'smashp;' => { output->first = 0x2a33; fbreak; };
  'smeparsl;' => { output->first = 0x29e4; fbreak; };
  'smid;' => { output->first = 0x2223; fbreak; };
  'smile;' => { output->first = 0x2323; fbreak; };
  'smt;' => { output->first = 0x2aaa; fbreak; };
  'smte;' => { output->first = 0x2aac; fbreak; };
  'smtes;' => { output->first = 0x2aac; output->second = 0xfe00; fbreak; };
  'softcy;' => { output->first = 0x044c; fbreak; };
  'sol;' => { output->first = 0x2f; fbreak; };
  'solb;' => { output->first = 0x29c4; fbreak; };
  'solbar;' => { output->first = 0x233f; fbreak; };
  'sopf;' => { output->first = 0x0001d564; fbreak; };
  'spades;' => { output->first = 0x2660; fbreak; };
  'spadesuit;' => { output->first = 0x2660; fbreak; };
  'spar;' => { output->first = 0x2225; fbreak; };
  'sqcap;' => { output->first = 0x2293; fbreak; };
  'sqcaps;' => { output->first = 0x2293; output->second = 0xfe00; fbreak; };
  'sqcup;' => { output->first = 0x2294; fbreak; };
  'sqcups;' => { output->first = 0x2294; output->second = 0xfe00; fbreak; };
  'sqsub;' => { output->first = 0x228f; fbreak; };
  'sqsube;' => { output->first = 0x2291; fbreak; };
  'sqsubset;' => { output->first = 0x228f; fbreak; };
  'sqsubseteq;' => { output->first = 0x2291; fbreak; };
  'sqsup;' => { output->first = 0x2290; fbreak; };
  'sqsupe;' => { output->first = 0x2292; fbreak; };
  'sqsupset;' => { output->first = 0x2290; fbreak; };
  'sqsupseteq;' => { output->first = 0x2292; fbreak; };
  'squ;' => { output->first = 0x25a1; fbreak; };
  'square;' => { output->first = 0x25a1; fbreak; };
  'squarf;' => { output->first = 0x25aa; fbreak; };
  'squf;' => { output->first = 0x25aa; fbreak; };
  'srarr;' => { output->first = 0x2192; fbreak; };
  'sscr;' => { output->first = 0x0001d4c8; fbreak; };
  'ssetmn;' => { output->first = 0x2216; fbreak; };
  'ssmile;' => { output->first = 0x2323; fbreak; };
  'sstarf;' => { output->first = 0x22c6; fbreak; };
  'star;' => { output->first = 0x2606; fbreak; };
  'starf;' => { output->first = 0x2605; fbreak; };
  'straightepsilon;' => { output->first = 0x03f5; fbreak; };
  'straightphi;' => { output->first = 0x03d5; fbreak; };
  'strns;' => { output->first = 0xaf; fbreak; };
  'sub;' => { output->first = 0x2282; fbreak; };
  'subE;' => { output->first = 0x2ac5; fbreak; };
  'subdot;' => { output->first = 0x2abd; fbreak; };
  'sube;' => { output->first = 0x2286; fbreak; };
  'subedot;' => { output->first = 0x2ac3; fbreak; };
  'submult;' => { output->first = 0x2ac1; fbreak; };
  'subnE;' => { output->first = 0x2acb; fbreak; };
  'subne;' => { output->first = 0x228a; fbreak; };
  'subplus;' => { output->first = 0x2abf; fbreak; };
  'subrarr;' => { output->first = 0x2979; fbreak; };
  'subset;' => { output->first = 0x2282; fbreak; };
  'subseteq;' => { output->first = 0x2286; fbreak; };
  'subseteqq;' => { output->first = 0x2ac5; fbreak; };
  'subsetneq;' => { output->first = 0x228a; fbreak; };
  'subsetneqq;' => { output->first = 0x2acb; fbreak; };
  'subsim;' => { output->first = 0x2ac7; fbreak; };
  'subsub;' => { output->first = 0x2ad5; fbreak; };
  'subsup;' => { output->first = 0x2ad3; fbreak; };
  'succ;' => { output->first = 0x227b; fbreak; };
  'succapprox;' => { output->first = 0x2ab8; fbreak; };
  'succcurlyeq;' => { output->first = 0x227d; fbreak; };
  'succeq;' => { output->first = 0x2ab0; fbreak; };
  'succnapprox;' => { output->first = 0x2aba; fbreak; };
  'succneqq;' => { output->first = 0x2ab6; fbreak; };
  'succnsim;' => { output->first = 0x22e9; fbreak; };
  'succsim;' => { output->first = 0x227f; fbreak; };
  'sum;' => { output->first = 0x2211; fbreak; };
  'sung;' => { output->first = 0x266a; fbreak; };
  'sup1;' => { output->first = 0xb9; fbreak; };
  'sup1' => { output->first = 0xb9; fbreak; };
  'sup2;' => { output->first = 0xb2; fbreak; };
  'sup2' => { output->first = 0xb2; fbreak; };
  'sup3;' => { output->first = 0xb3; fbreak; };
  'sup3' => { output->first = 0xb3; fbreak; };
  'sup;' => { output->first = 0x2283; fbreak; };
  'supE;' => { output->first = 0x2ac6; fbreak; };
  'supdot;' => { output->first = 0x2abe; fbreak; };
  'supdsub;' => { output->first = 0x2ad8; fbreak; };
  'supe;' => { output->first = 0x2287; fbreak; };
  'supedot;' => { output->first = 0x2ac4; fbreak; };
  'suphsol;' => { output->first = 0x27c9; fbreak; };
  'suphsub;' => { output->first = 0x2ad7; fbreak; };
  'suplarr;' => { output->first = 0x297b; fbreak; };
  'supmult;' => { output->first = 0x2ac2; fbreak; };
  'supnE;' => { output->first = 0x2acc; fbreak; };
  'supne;' => { output->first = 0x228b; fbreak; };
  'supplus;' => { output->first = 0x2ac0; fbreak; };
  'supset;' => { output->first = 0x2283; fbreak; };
  'supseteq;' => { output->first = 0x2287; fbreak; };
  'supseteqq;' => { output->first = 0x2ac6; fbreak; };
  'supsetneq;' => { output->first = 0x228b; fbreak; };
  'supsetneqq;' => { output->first = 0x2acc; fbreak; };
  'supsim;' => { output->first = 0x2ac8; fbreak; };
  'supsub;' => { output->first = 0x2ad4; fbreak; };
  'supsup;' => { output->first = 0x2ad6; fbreak; };
  'swArr;' => { output->first = 0x21d9; fbreak; };
  'swarhk;' => { output->first = 0x2926; fbreak; };
  'swarr;' => { output->first = 0x2199; fbreak; };
  'swarrow;' => { output->first = 0x2199; fbreak; };
  'swnwar;' => { output->first = 0x292a; fbreak; };
  'szlig;' => { output->first = 0xdf; fbreak; };
  'szlig' => { output->first = 0xdf; fbreak; };
  'target;' => { output->first = 0x2316; fbreak; };
  'tau;' => { output->first = 0x03c4; fbreak; };
  'tbrk;' => { output->first = 0x23b4; fbreak; };
  'tcaron;' => { output->first = 0x0165; fbreak; };
  'tcedil;' => { output->first = 0x0163; fbreak; };
  'tcy;' => { output->first = 0x0442; fbreak; };
  'tdot;' => { output->first = 0x20db; fbreak; };
  'telrec;' => { output->first = 0x2315; fbreak; };
  'tfr;' => { output->first = 0x0001d531; fbreak; };
  'there4;' => { output->first = 0x2234; fbreak; };
  'therefore;' => { output->first = 0x2234; fbreak; };
  'theta;' => { output->first = 0x03b8; fbreak; };
  'thetasym;' => { output->first = 0x03d1; fbreak; };
  'thetav;' => { output->first = 0x03d1; fbreak; };
  'thickapprox;' => { output->first = 0x2248; fbreak; };
  'thicksim;' => { output->first = 0x223c; fbreak; };
  'thinsp;' => { output->first = 0x2009; fbreak; };
  'thkap;' => { output->first = 0x2248; fbreak; };
  'thksim;' => { output->first = 0x223c; fbreak; };
  'thorn;' => { output->first = 0xfe; fbreak; };
  'thorn' => { output->first = 0xfe; fbreak; };
  'tilde;' => { output->first = 0x02dc; fbreak; };
  'times;' => { output->first = 0xd7; fbreak; };
  'times' => { output->first = 0xd7; fbreak; };
  'timesb;' => { output->first = 0x22a0; fbreak; };
  'timesbar;' => { output->first = 0x2a31; fbreak; };
  'timesd;' => { output->first = 0x2a30; fbreak; };
  'tint;' => { output->first = 0x222d; fbreak; };
  'toea;' => { output->first = 0x2928; fbreak; };
  'top;' => { output->first = 0x22a4; fbreak; };
  'topbot;' => { output->first = 0x2336; fbreak; };
  'topcir;' => { output->first = 0x2af1; fbreak; };
  'topf;' => { output->first = 0x0001d565; fbreak; };
  'topfork;' => { output->first = 0x2ada; fbreak; };
  'tosa;' => { output->first = 0x2929; fbreak; };
  'tprime;' => { output->first = 0x2034; fbreak; };
  'trade;' => { output->first = 0x2122; fbreak; };
  'triangle;' => { output->first = 0x25b5; fbreak; };
  'triangledown;' => { output->first = 0x25bf; fbreak; };
  'triangleleft;' => { output->first = 0x25c3; fbreak; };
  'trianglelefteq;' => { output->first = 0x22b4; fbreak; };
  'triangleq;' => { output->first = 0x225c; fbreak; };
  'triangleright;' => { output->first = 0x25b9; fbreak; };
  'trianglerighteq;' => { output->first = 0x22b5; fbreak; };
  'tridot;' => { output->first = 0x25ec; fbreak; };
  'trie;' => { output->first = 0x225c; fbreak; };
  'triminus;' => { output->first = 0x2a3a; fbreak; };
  'triplus;' => { output->first = 0x2a39; fbreak; };
  'trisb;' => { output->first = 0x29cd; fbreak; };
  'tritime;' => { output->first = 0x2a3b; fbreak; };
  'trpezium;' => { output->first = 0x23e2; fbreak; };
  'tscr;' => { output->first = 0x0001d4c9; fbreak; };
  'tscy;' => { output->first = 0x0446; fbreak; };
  'tshcy;' => { output->first = 0x045b; fbreak; };
  'tstrok;' => { output->first = 0x0167; fbreak; };
  'twixt;' => { output->first = 0x226c; fbreak; };
  'twoheadleftarrow;' => { output->first = 0x219e; fbreak; };
  'twoheadrightarrow;' => { output->first = 0x21a0; fbreak; };
  'uArr;' => { output->first = 0x21d1; fbreak; };
  'uHar;' => { output->first = 0x2963; fbreak; };
  'uacute;' => { output->first = 0xfa; fbreak; };
  'uacute' => { output->first = 0xfa; fbreak; };
  'uarr;' => { output->first = 0x2191; fbreak; };
  'ubrcy;' => { output->first = 0x045e; fbreak; };
  'ubreve;' => { output->first = 0x016d; fbreak; };
  'ucirc;' => { output->first = 0xfb; fbreak; };
  'ucirc' => { output->first = 0xfb; fbreak; };
  'ucy;' => { output->first = 0x0443; fbreak; };
  'udarr;' => { output->first = 0x21c5; fbreak; };
  'udblac;' => { output->first = 0x0171; fbreak; };
  'udhar;' => { output->first = 0x296e; fbreak; };
  'ufisht;' => { output->first = 0x297e; fbreak; };
  'ufr;' => { output->first = 0x0001d532; fbreak; };
  'ugrave;' => { output->first = 0xf9; fbreak; };
  'ugrave' => { output->first = 0xf9; fbreak; };
  'uharl;' => { output->first = 0x21bf; fbreak; };
  'uharr;' => { output->first = 0x21be; fbreak; };
  'uhblk;' => { output->first = 0x2580; fbreak; };
  'ulcorn;' => { output->first = 0x231c; fbreak; };
  'ulcorner;' => { output->first = 0x231c; fbreak; };
  'ulcrop;' => { output->first = 0x230f; fbreak; };
  'ultri;' => { output->first = 0x25f8; fbreak; };
  'umacr;' => { output->first = 0x016b; fbreak; };
  'uml;' => { output->first = 0xa8; fbreak; };
  'uml' => { output->first = 0xa8; fbreak; };
  'uogon;' => { output->first = 0x0173; fbreak; };
  'uopf;' => { output->first = 0x0001d566; fbreak; };
  'uparrow;' => { output->first = 0x2191; fbreak; };
  'updownarrow;' => { output->first = 0x2195; fbreak; };
  'upharpoonleft;' => { output->first = 0x21bf; fbreak; };
  'upharpoonright;' => { output->first = 0x21be; fbreak; };
  'uplus;' => { output->first = 0x228e; fbreak; };
  'upsi;' => { output->first = 0x03c5; fbreak; };
  'upsih;' => { output->first = 0x03d2; fbreak; };
  'upsilon;' => { output->first = 0x03c5; fbreak; };
  'upuparrows;' => { output->first = 0x21c8; fbreak; };
  'urcorn;' => { output->first = 0x231d; fbreak; };
  'urcorner;' => { output->first = 0x231d; fbreak; };
  'urcrop;' => { output->first = 0x230e; fbreak; };
  'uring;' => { output->first = 0x016f; fbreak; };
  'urtri;' => { output->first = 0x25f9; fbreak; };
  'uscr;' => { output->first = 0x0001d4ca; fbreak; };
  'utdot;' => { output->first = 0x22f0; fbreak; };
  'utilde;' => { output->first = 0x0169; fbreak; };
  'utri;' => { output->first = 0x25b5; fbreak; };
  'utrif;' => { output->first = 0x25b4; fbreak; };
  'uuarr;' => { output->first = 0x21c8; fbreak; };
  'uuml;' => { output->first = 0xfc; fbreak; };
  'uuml' => { output->first = 0xfc; fbreak; };
  'uwangle;' => { output->first = 0x29a7; fbreak; };
  'vArr;' => { output->first = 0x21d5; fbreak; };
  'vBar;' => { output->first = 0x2ae8; fbreak; };
  'vBarv;' => { output->first = 0x2ae9; fbreak; };
  'vDash;' => { output->first = 0x22a8; fbreak; };
  'vangrt;' => { output->first = 0x299c; fbreak; };
  'varepsilon;' => { output->first = 0x03f5; fbreak; };
  'varkappa;' => { output->first = 0x03f0; fbreak; };
  'varnothing;' => { output->first = 0x2205; fbreak; };
  'varphi;' => { output->first = 0x03d5; fbreak; };
  'varpi;' => { output->first = 0x03d6; fbreak; };
  'varpropto;' => { output->first = 0x221d; fbreak; };
  'varr;' => { output->first = 0x2195; fbreak; };
  'varrho;' => { output->first = 0x03f1; fbreak; };
  'varsigma;' => { output->first = 0x03c2; fbreak; };
  'varsubsetneq;' => { output->first = 0x228a; output->second = 0xfe00; fbreak; };
  'varsubsetneqq;' => { output->first = 0x2acb; output->second = 0xfe00; fbreak; };
  'varsupsetneq;' => { output->first = 0x228b; output->second = 0xfe00; fbreak; };
  'varsupsetneqq;' => { output->first = 0x2acc; output->second = 0xfe00; fbreak; };
  'vartheta;' => { output->first = 0x03d1; fbreak; };
  'vartriangleleft;' => { output->first = 0x22b2; fbreak; };
  'vartriangleright;' => { output->first = 0x22b3; fbreak; };
  'vcy;' => { output->first = 0x0432; fbreak; };
  'vdash;' => { output->first = 0x22a2; fbreak; };
  'vee;' => { output->first = 0x2228; fbreak; };
  'veebar;' => { output->first = 0x22bb; fbreak; };
  'veeeq;' => { output->first = 0x225a; fbreak; };
  'vellip;' => { output->first = 0x22ee; fbreak; };
  'verbar;' => { output->first = 0x7c; fbreak; };
  'vert;' => { output->first = 0x7c; fbreak; };
  'vfr;' => { output->first = 0x0001d533; fbreak; };
  'vltri;' => { output->first = 0x22b2; fbreak; };
  'vnsub;' => { output->first = 0x2282; output->second = 0x20d2; fbreak; };
  'vnsup;' => { output->first = 0x2283; output->second = 0x20d2; fbreak; };
  'vopf;' => { output->first = 0x0001d567; fbreak; };
  'vprop;' => { output->first = 0x221d; fbreak; };
  'vrtri;' => { output->first = 0x22b3; fbreak; };
  'vscr;' => { output->first = 0x0001d4cb; fbreak; };
  'vsubnE;' => { output->first = 0x2acb; output->second = 0xfe00; fbreak; };
  'vsubne;' => { output->first = 0x228a; output->second = 0xfe00; fbreak; };
  'vsupnE;' => { output->first = 0x2acc; output->second = 0xfe00; fbreak; };
  'vsupne;' => { output->first = 0x228b; output->second = 0xfe00; fbreak; };
  'vzigzag;' => { output->first = 0x299a; fbreak; };
  'wcirc;' => { output->first = 0x0175; fbreak; };
  'wedbar;' => { output->first = 0x2a5f; fbreak; };
  'wedge;' => { output->first = 0x2227; fbreak; };
  'wedgeq;' => { output->first = 0x2259; fbreak; };
  'weierp;' => { output->first = 0x2118; fbreak; };
  'wfr;' => { output->first = 0x0001d534; fbreak; };
  'wopf;' => { output->first = 0x0001d568; fbreak; };
  'wp;' => { output->first = 0x2118; fbreak; };
  'wr;' => { output->first = 0x2240; fbreak; };
  'wreath;' => { output->first = 0x2240; fbreak; };
  'wscr;' => { output->first = 0x0001d4cc; fbreak; };
  'xcap;' => { output->first = 0x22c2; fbreak; };
  'xcirc;' => { output->first = 0x25ef; fbreak; };
  'xcup;' => { output->first = 0x22c3; fbreak; };
  'xdtri;' => { output->first = 0x25bd; fbreak; };
  'xfr;' => { output->first = 0x0001d535; fbreak; };
  'xhArr;' => { output->first = 0x27fa; fbreak; };
  'xharr;' => { output->first = 0x27f7; fbreak; };
  'xi;' => { output->first = 0x03be; fbreak; };
  'xlArr;' => { output->first = 0x27f8; fbreak; };
  'xlarr;' => { output->first = 0x27f5; fbreak; };
  'xmap;' => { output->first = 0x27fc; fbreak; };
  'xnis;' => { output->first = 0x22fb; fbreak; };
  'xodot;' => { output->first = 0x2a00; fbreak; };
  'xopf;' => { output->first = 0x0001d569; fbreak; };
  'xoplus;' => { output->first = 0x2a01; fbreak; };
  'xotime;' => { output->first = 0x2a02; fbreak; };
  'xrArr;' => { output->first = 0x27f9; fbreak; };
  'xrarr;' => { output->first = 0x27f6; fbreak; };
  'xscr;' => { output->first = 0x0001d4cd; fbreak; };
  'xsqcup;' => { output->first = 0x2a06; fbreak; };
  'xuplus;' => { output->first = 0x2a04; fbreak; };
  'xutri;' => { output->first = 0x25b3; fbreak; };
  'xvee;' => { output->first = 0x22c1; fbreak; };
  'xwedge;' => { output->first = 0x22c0; fbreak; };
  'yacute;' => { output->first = 0xfd; fbreak; };
  'yacute' => { output->first = 0xfd; fbreak; };
  'yacy;' => { output->first = 0x044f; fbreak; };
  'ycirc;' => { output->first = 0x0177; fbreak; };
  'ycy;' => { output->first = 0x044b; fbreak; };
  'yen;' => { output->first = 0xa5; fbreak; };
  'yen' => { output->first = 0xa5; fbreak; };
  'yfr;' => { output->first = 0x0001d536; fbreak; };
  'yicy;' => { output->first = 0x0457; fbreak; };
  'yopf;' => { output->first = 0x0001d56a; fbreak; };
  'yscr;' => { output->first = 0x0001d4ce; fbreak; };
  'yucy;' => { output->first = 0x044e; fbreak; };
  'yuml;' => { output->first = 0xff; fbreak; };
  'yuml' => { output->first = 0xff; fbreak; };
  'zacute;' => { output->first = 0x017a; fbreak; };
  'zcaron;' => { output->first = 0x017e; fbreak; };
  'zcy;' => { output->first = 0x0437; fbreak; };
  'zdot;' => { output->first = 0x017c; fbreak; };
  'zeetrf;' => { output->first = 0x2128; fbreak; };
  'zeta;' => { output->first = 0x03b6; fbreak; };
  'zfr;' => { output->first = 0x0001d537; fbreak; };
  'zhcy;' => { output->first = 0x0436; fbreak; };
  'zigrarr;' => { output->first = 0x21dd; fbreak; };
  'zopf;' => { output->first = 0x0001d56b; fbreak; };
  'zscr;' => { output->first = 0x0001d4cf; fbreak; };
  'zwj;' => { output->first = 0x200d; fbreak; };
  'zwnj;' => { output->first = 0x200c; fbreak; };
*|;
}%%

%% write data;

static inline bool is_attr_ok(unsigned char c) {
    switch(c) {
        case '=':
        case 'a':
        case 'b':
        case 'c':
        case 'd':
        case 'e':
        case 'f':
        case 'g':
        case 'h':
        case 'i':
        case 'j':
        case 'k':
        case 'l':
        case 'm':
        case 'n':
        case 'o':
        case 'p':
        case 'q':
        case 'r':
        case 's':
        case 't':
        case 'u':
        case 'v':
        case 'w':
        case 'x':
        case 'y':
        case 'z':
        case 'A':
        case 'B':
        case 'C':
        case 'D':
        case 'E':
        case 'F':
        case 'G':
        case 'H':
        case 'I':
        case 'J':
        case 'K':
        case 'L':
        case 'M':
        case 'N':
        case 'O':
        case 'P':
        case 'Q':
        case 'R':
        case 'S':
        case 'T':
        case 'U':
        case 'V':
        case 'W':
        case 'X':
        case 'Y':
        case 'Z':
        case '0':
        case '1':
        case '2':
        case '3':
        case '4':
        case '5':
        case '6':
        case '7':
        case '8':
        case '9':
            return true;
            break;
        default:
            break;
    }
    return false;
}

static bool consume_named_ref(
    struct GumboInternalParser* parser, Utf8Iterator* input, bool is_in_attribute,
    OneOrTwoCodepoints* output) {
  assert(output->first == kGumboNoChar);
  const char* p = utf8iterator_get_char_pointer(input);
  const char* pe = utf8iterator_get_end_pointer(input);
  const char* eof = pe;
  const char* te = 0;
  const char *ts, *start;
  int cs, act;
  bool matched;

  %% write init;
  // Avoid unused variable warnings.
  (void) act;
  (void) ts;
  (void) matched;

  start = p;
  %% write exec;

  if (cs >= %%{ write first_final; }%%) {
    assert(output->first != kGumboNoChar);
    char last_char = *(te - 1);
    int len = te - start;
    if (last_char == ';') {
      matched = utf8iterator_maybe_consume_match(input, start, len, true);
      assert(matched);
      return true;
    } else if (is_in_attribute && (is_attr_ok(*te))) {
      output->first = kGumboNoChar;
      output->second = kGumboNoChar;
      utf8iterator_reset(input);
      return true;
    } else {
      GumboStringPiece bad_ref;
      bad_ref.length = te - start;
      bad_ref.data = start;
      add_named_reference_error(
          parser, input, GUMBO_ERR_NAMED_CHAR_REF_WITHOUT_SEMICOLON, bad_ref);
      matched = utf8iterator_maybe_consume_match(input, start, len, true);
      assert(matched);
      return false;
    }
  } else {
    output->first = kGumboNoChar;
    output->second = kGumboNoChar;
    bool status = maybe_add_invalid_named_reference(parser, input);
    utf8iterator_reset(input);
    return status;
  }
}

bool consume_char_ref(
    struct GumboInternalParser* parser, struct GumboInternalUtf8Iterator* input,
    int additional_allowed_char, bool is_in_attribute,
    OneOrTwoCodepoints* output) {
  utf8iterator_mark(input);
  utf8iterator_next(input);
  int c = utf8iterator_current(input);
  output->first = kGumboNoChar;
  output->second = kGumboNoChar;
  if (c == additional_allowed_char) {
    utf8iterator_reset(input);
    output->first = kGumboNoChar;
    return true;
  }
  switch (utf8iterator_current(input)) {
    case '\t':
    case '\n':
    case '\f':
    case ' ':
    case '<':
    case '&':
    case -1:
      utf8iterator_reset(input);
      return true;
    case '#':
      return consume_numeric_ref(parser, input, &output->first);
    default:
      return consume_named_ref(parser, input, is_in_attribute, output);
  }
}
