/*
 * char_utf8.h - UTF8 encoding interface
 *
 *  Copyright(C) 2000 by Shiro Kawai (shiro@acm.org)
 *
 *  Permission to use, copy, modify, ditribute this software and
 *  accompanying documentation for any purpose is hereby granted,
 *  provided that existing copyright notices are retained in all
 *  copies and that this notice is included verbatim in all
 *  distributions.
 *  This software is provided as is, without express or implied
 *  warranty.  In no circumstances the author(s) shall be liable
 *  for any damages arising out of the use of this software.
 *
 *  $Id: char_utf_8.h,v 1.1 2001-04-26 07:04:47 shiro Exp $
 */

#ifndef SCM_CHAR_ENCODING_BODY

#define SCM_CHAR_ENCODING_NAME "utf-8"

extern char Scm_CharSizeTable[];
extern ScmChar Scm_CharUtf8Getc(const char *);
extern void Scm_CharUtf8Putc(char *, ScmChar);

#define SCM_CHAR_NFOLLOWS(ch) ((int)Scm_CharSizeTable[(ch)])

#define SCM_CHAR_NBYTES(ch)                     \
    (((ch) < 0x80) ? 1 :                        \
     (((ch) < 0x800) ? 2 :                      \
      (((ch) < 0x10000) ? 3 :                   \
       (((ch) < 0x200000) ? 4 :                 \
        (((ch) < 0x4000000) ? 5 : 6)))))

#define SCM_CHAR_MAX_BYTES     6

#define SCM_CHAR_GET(cp, ch)                            \
    do {                                                \
        if (((ch) = (unsigned char)*(cp)) >= 0x80) {    \
            (ch) = Scm_CharUtf8Getc(cp);                \
        }                                               \
    } while (0)

#define SCM_CHAR_BACKWARD(cp, start, result)                            \
    do {                                                                \
        (result) = (cp);                                                \
        while ((result) >= (start)) {                                   \
            if ((result) + SCM_CHAR_NFOLLOWS(*(result)) + 1 == (cp)) {  \
                break;                                                  \
            }                                                           \
            (result)--;                                                 \
        }                                                               \
        if ((result) < (start)) (result) = NULL;                        \
    } while (0)

#define SCM_CHAR_PUT(cp, ch)                    \
    do {                                        \
        if (ch >= 0x80) {                       \
            Scm_CharUtf8Putc(cp, ch);           \
        } else {                                \
            *(cp) = (ch);                       \
        }                                       \
    } while (0)

#else  /* !SCM_CHAR_ENCODING_BODY */

char Scm_CharSizeTable[256] = {
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, /* 0x */
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, /* 1x */
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, /* 2x */
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, /* 3x */
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, /* 4x */
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, /* 5x */
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, /* 6x */
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, /* 7x */
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, /* 8x */
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, /* 9x */
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, /* ax */
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, /* bx */
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, /* cx */
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, /* dx */
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, /* ex */
    3, 3, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 0, 0  /* fx */
};

ScmChar Scm_CharUtf8Getc(const char *cp)
{
    ScmChar ch;
    unsigned char *ucp = (unsigned char *)cp;
    unsigned char first = *ucp++;
    if (first < 0x80) { /* nothing to do */ }
    else if (first < 0xc0) { ch = SCM_CHAR_INVALID; }
    else if (first < 0xe0) {
        ch = first&0x1f;
        ch = (ch<<6) | (*ucp++&0x3f);
        if (ch < 0x80) ch = SCM_CHAR_INVALID;
    }
    else if (first < 0xf0) {
        ch = first&0x0f;
        ch = (ch<<6) | (*ucp++&0x3f);
        ch = (ch<<6) | (*ucp++&0x3f);
        if (ch < 0x800) ch = SCM_CHAR_INVALID;
    }
    else if (first < 0xf8) {
        ch = first&0x07;
        ch = (ch<<6) | (*ucp++&0x3f);
        ch = (ch<<6) | (*ucp++&0x3f);
        ch = (ch<<6) | (*ucp++&0x3f);
        if (ch < 0x10000) ch = SCM_CHAR_INVALID;
    }
    else if (first < 0xfc) {
        ch = first&0x03;
        ch = (ch<<6) | (*ucp++&0x3f);
        ch = (ch<<6) | (*ucp++&0x3f);
        ch = (ch<<6) | (*ucp++&0x3f);
        ch = (ch<<6) | (*ucp++&0x3f);
        if (ch < 0x200000) ch = SCM_CHAR_INVALID;
    }
    else if (first < 0xfe) {
        ch = first&0x01;
        ch = (ch<<6) | (*ucp++&0x3f);
        ch = (ch<<6) | (*ucp++&0x3f);
        ch = (ch<<6) | (*ucp++&0x3f);
        ch = (ch<<6) | (*ucp++&0x3f);
        ch = (ch<<6) | (*ucp++&0x3f);
        if (ch < 0x4000000) ch = SCM_CHAR_INVALID;
    }
    else {
        ch = SCM_CHAR_INVALID;
    }
    return ch;
}

void Scm_CharUtf8Putc(char *cp, ScmChar ch)
{
    if (ch < 0x80) {
        *cp = ch;
    }
    else if (ch < 0x800) {
        *cp++ = ((ch>>6)&0x1f) | 0xc0;
        *cp = (ch&0x3f) | 0x80;
    }
    else if (ch < 0x10000) {
        *cp++ = ((ch>>12)&0x0f) | 0xe0;
        *cp++ = ((ch>>6)&0x3f) | 0x80;
        *cp = (ch&0x3f) | 0x80;
    }
    else if (ch < 0x200000) {
        *cp++ = ((ch>>18)&0x07) | 0xf0;
        *cp++ = ((ch>>12)&0x3f) | 0x80;
        *cp++ = ((ch>>6)&0x3f) | 0x80;
        *cp = (ch&0x3f) | 0x80;
    }
    else if (ch < 0x4000000) {
        *cp++ = ((ch>>24)&0x03) | 0xf8;
        *cp++ = ((ch>>18)&0x3f) | 0x80;
        *cp++ = ((ch>>12)&0x3f) | 0x80;
        *cp++ = ((ch>>6)&0x3f) | 0x80;
        *cp = (ch&0x3f) | 0x80;
    } else {
        *cp++ = ((ch>>30)&0x1) | 0xfc;
        *cp++ = ((ch>>24)&0x3f) | 0x80;
        *cp++ = ((ch>>18)&0x3f) | 0x80;
        *cp++ = ((ch>>12)&0x3f) | 0x80;
        *cp++ = ((ch>>6)&0x3f) | 0x80;
        *cp++ = (ch&0x3f) | 0x80;
    }
}

#endif /* !SCM_CHAR_ENCODING_BODY */
