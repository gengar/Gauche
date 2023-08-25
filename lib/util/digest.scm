;;;
;;; digest - abstract base class for message digest algorithms
;;;
;;;   Copyright (c) 2002-2003 Kimura Fuyuki, All rights reserved.
;;;
;;;   Redistribution and use in source and binary forms, with or without
;;;   modification, are permitted provided that the following conditions
;;;   are met:
;;;
;;;   1. Redistributions of source code must retain the above copyright
;;;      notice, this list of conditions and the following disclaimer.
;;;
;;;   2. Redistributions in binary form must reproduce the above copyright
;;;      notice, this list of conditions and the following disclaimer in the
;;;      documentation and/or other materials provided with the distribution.
;;;
;;;   3. Neither the name of the authors nor the names of its contributors
;;;      may be used to endorse or promote products derived from this
;;;      software without specific prior written permission.
;;;
;;;   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;;;   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;;;   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;;;   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;;;   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;;;   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
;;;   TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
;;;   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
;;;   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;;   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;;   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;;;

;; An abstract base- and meta-class of message digest algorithms.
;; The concrete implementation is given in modules such as
;; rfc.md5 and rfc.sha.

(define-module util.digest
  (use gauche.uvector)
  (use rfc.base64)
  (export <message-digest-algorithm> <message-digest-algorithm-meta>
          digest-update! digest-final!
          digest digest-to digest-string digest-string-to
          digest-hexify)
  )
(select-module util.digest)

(autoload gauche.vport open-input-uvector)

(define-class <message-digest-algorithm-meta> (<class>)
  ;; Block size (in bytes) used in HMAC, determined by each algorithm.
  ;; Older algorithms uses 64, while SHA-384/512 uses 128.
  ((hmac-block-size :init-keyword :hmac-block-size :init-value 64)))

(define-class <message-digest-algorithm> ()
  ()
  :metaclass <message-digest-algorithm-meta>)

(define-method digest-update! ((self <message-digest-algorithm>) data)
  #f)
(define-method digest-final! ((self <message-digest-algorithm>))
  #f)
(define-method digest ((digester <message-digest-algorithm-meta>))
  #f)

(define-method digest-to ((target <string-meta>)
                          (digester <message-digest-algorithm-meta>))
  (digest digester))
(define-method digest-to ((target <u8vector-meta>)
                          (digester <message-digest-algorithm-meta>))
  (string->u8vector (digest digester)))

(define-method digest-string ((digester <message-digest-algorithm-meta>)
                              message)
  (assume-type message (</> <string> <u8vector>))
  (cond
   [(string? message)
    (with-input-from-string message (cut digest digester))]
   [(u8vector? message)
    (with-input-from-port (open-input-uvector message)
      (cut digest digester))]))

(define-method digest-string-to ((target <string-meta>)
                                 (digester <message-digest-algorithm-meta>)
                                 message)
  (digest-string digester message))
(define-method digest-string-to ((target <u8vector-meta>)
                                 (digester <message-digest-algorithm-meta>)
                                 message)
  (string->u8vector (digest-string digester message)))

;; Special targets:
;;   base64
;;   base64url
;;   base64url-nopad
;;   base32
;;   base32hex
;;   base16
;;   hex
(define-method digest-string-to ((target <symbol>)
                                 (digester <message-digest-algorithm-meta>)
                                 message)
  (define encoder
    (case target
      [(base64) base64-encode-string]
      [(base64url) (cut base64-encode-string <> :url-safe #t)]
      [(base64url-nopad) (cut base64-encode-string <>
                              :url-safe #t :omit-padding #t)]
      [(base32) base32-encode-string]
      [(base32hex) base32hex-encode-string]
      [(base16) base16-encode-string]
      [(hex) digest-hexify]))
  (encoder (digest-string digester message)))

;; OBSOLETED
;;   Use base16-encode-*, or digest-string-to with predefined encoder targets.
(define (digest-hexify data)
  (cond
   [(u8vector? data) (base16-encode-bytevector data :lowercase #t)]
   [(string? data) (base16-encode-string data :lowercase #t)]
   [else -    (error "data must be either u8vector or string, but got:" data)]))
