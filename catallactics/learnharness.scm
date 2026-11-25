;;; learnharness.scm --- LearnHarness from the upstream Debian release.
;;;
;;; LearnHarness is an Electron shell around a Next standalone server.  There
;;; is no practical Guix source build: the application needs a newer Node and
;;; Electron than Guix provides, a lockfile with more than a thousand npm
;;; packages and electron-builder's Linux assembly pipeline.  The upstream
;;; .deb is the hash-pinned release artifact, like opencode and autolith; this
;;; package adapts it to Guix.
;;;
;;; The build patches the ELF interpreter, supplies the runtime libraries
;;; through the wrapper, and installs the desktop entry and icon.  Stock Mesa
;;; and libglvnd are used so the package is independent of any machine's
;;; graphics stack.
;;;
;;; The upstream updater installs the next .deb through dpkg/apt.  A Guix
;;; package owns its version, so the feed metadata is removed: electron-updater
;;; fails its check in the usual non-fatal way instead of downloading a package
;;; it cannot install.

(define-module (catallactics learnharness)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages cups)
  #:use-module (gnu packages elf)
  #:use-module (gnu packages fontutils)
  #:use-module (gnu packages freedesktop)
  #:use-module (gnu packages gcc)
  #:use-module (gnu packages gl)
  #:use-module (gnu packages glib)
  #:use-module (gnu packages gnome)
  #:use-module (gnu packages gtk)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages nss)
  #:use-module (gnu packages pulseaudio)
  #:use-module (gnu packages xdisorg)
  #:use-module (gnu packages xorg)
  #:use-module (gnu packages xml)
  #:use-module (guix build-system trivial)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (guix packages)
  #:export (learnharness-bin))

;; Only these libraries go on LD_LIBRARY_PATH.  Everything they need in turn
;; is found through the RUNPATHs Guix gives those packages.  The X11 client
;; libraries are required because the prebuilt Electron binary links them at
;; load time even when Ozone selects Wayland; no X server is involved.
(define %runtime-packages
  (list alsa-lib
        at-spi2-core
        cairo
        cups
        dbus
        eudev
        expat
        fontconfig
        gdk-pixbuf
        glib
        gtk+
        libnotify
        librsvg
        libsecret
        libx11
        libxcb
        libxcomposite
        libxcursor
        libxdamage
        libxext
        libxfixes
        libxkbcommon
        libxrandr
        libxscrnsaver
        libxtst
        nspr
        nss
        pango
        pulseaudio
        util-linux
        wayland))

(define-public learnharness-bin
  (package
    (name "learnharness-bin")
    (version "0.7.0")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://github.com/amosblomqvist/learnharness/releases/download/v"
             version "/LearnHarness-" version "-amd64.deb"))
       (file-name (string-append "LearnHarness-" version "-amd64.deb"))
       (sha256
        (base32 "1mi6ac8fxqgddr4b0kr1fk4b9lqxyq5w7z7qns8r3lf676rhjm9n"))))
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))

          (define (extract-data archive target)
            (cond
              ((string-suffix? ".xz" archive)
               (invoke "tar"
                       "-xJf"
                       archive
                       "-C"
                       target
                       "--no-same-owner"))
              ((string-suffix? ".zst" archive)
               (invoke "tar"
                       "--zstd"
                       "-xf"
                       archive
                       "-C"
                       target
                       "--no-same-owner"))
              ((string-suffix? ".gz" archive)
               (invoke "tar"
                       "-xzf"
                       archive
                       "-C"
                       target
                       "--no-same-owner"))
              (else (error "learnharness: unexpected data archive" archive))))

          (let* ((out #$output)
                 (src (assoc-ref %build-inputs "source"))
                 (binutils (assoc-ref %build-inputs "binutils"))
                 (patchelf (assoc-ref %build-inputs "patchelf"))
                 (tar (assoc-ref %build-inputs "tar"))
                 (xz (assoc-ref %build-inputs "xz"))
                 (gcc-lib (assoc-ref %build-inputs "gcc"))
                 (work (getcwd))
                 (deb (string-append work "/deb"))
                 (extracted (string-append work "/extracted"))
                 (app (string-append out "/libexec/learnharness"))
                 (bin (string-append out "/bin")))
            (setenv "PATH"
                    (string-append binutils
                                   "/bin:"
                                   tar
                                   "/bin:"
                                   xz
                                   "/bin:"
                                   patchelf
                                   "/bin:"
                                   (getenv "PATH")))

            ;; A Debian package is an ar archive holding control.tar.* and
            ;; data.tar.*.  Only the data member is needed.
            (mkdir-p deb)
            (with-directory-excursion deb
              (invoke "ar" "x" src))
            (mkdir-p extracted)
            (let ((data (car (find-files deb "^data\\.tar\\."))))
              (extract-data data extracted))

            (mkdir-p (dirname app))
            (copy-recursively (string-append extracted "/opt/LearnHarness")
                              app
                              #:keep-mtime? #t
                              #:log #f)

            ;; The bundle expects /lib64, which Guix does not provide.  Patch
            ;; the three executables; the shipped libraries and native .node
            ;; modules are found through LD_LIBRARY_PATH from the wrapper.
            (for-each (lambda (file)
                        (let ((path (string-append app "/" file)))
                          (chmod path #o755)
                          (invoke (string-append patchelf "/bin/patchelf")
                                  "--set-interpreter"
                                  #$(file-append glibc
                                                 "/lib/ld-linux-x86-64.so.2")
                                  path)))
                      '("learnharness" "chrome_crashpad_handler"
                        "chrome-sandbox"))

            ;; A Guix package must not install a .deb on quit.  Drop the
            ;; electron-updater feed metadata (see the header comment).
            (for-each (lambda (file)
                        (let ((path (string-append app "/resources/" file)))
                          (when (file-exists? path)
                            (delete-file path))))
                      '("app-update.yml" "package-type"))

            ;; Desktop integration: the upstream Exec hard-codes /opt.
            (let* ((applications (string-append out "/share/applications"))
                   (desktop-name "learnharness.desktop")
                   (desktop (string-append extracted
                                           "/usr/share/applications/"
                                           desktop-name)))
              (mkdir-p applications)
              (copy-file desktop
                         (string-append applications "/" desktop-name))
              (chmod (string-append applications "/" desktop-name) #o644)
              (substitute* (string-append applications "/" desktop-name)
                (("/opt/LearnHarness/learnharness")
                 "learnharness")))

            (let ((icons (string-append out
                                        "/share/icons/hicolor/512x512/apps")))
              (mkdir-p icons)
              (copy-file (string-append extracted
                          "/usr/share/icons/hicolor/512x512/apps/"
                          "learnharness.png")
                         (string-append icons "/learnharness.png"))
              (chmod (string-append icons "/learnharness.png") #o644))

            (mkdir-p bin)
            (let* ((runtime-path (string-append #$(file-append
                                                   coreutils-minimal "/bin")
                                                ":"
                                                #$(file-append xdg-utils
                                                               "/bin")))
                   (library-path (string-join (append (list #$(file-append
                                                               libglvnd "/lib")
                                                            #$(file-append
                                                               mesa "/lib")
                                                            #$(file-append nss
                                                               "/lib/nss")
                                                            (string-append
                                                             gcc-lib "/lib"))
                                                      (list #$@(map (lambda (package
                                                                              )
                                                                      (file-append
                                                                       package
                                                                       "/lib"))
                                                                %runtime-packages)))
                                              ":"))
                   (wrapper (string-append bin "/learnharness")))
              (call-with-output-file wrapper
                (lambda (port)
                  (format port "#!~a\n"
                          #$(file-append bash-minimal "/bin/bash"))
                  (format port "set -euo pipefail\n")
                  (format port "export PATH=\"~a${PATH:+:$PATH}\"\n"
                          runtime-path)
                  (format port
                          (string-append "export LD_LIBRARY_PATH=\"~a"
                           "${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\"\n")
                          library-path)
                  (format port
                          (string-append "export FONTCONFIG_PATH=\"~a"
                           "${FONTCONFIG_PATH:+:$FONTCONFIG_PATH}\"\n")
                          #$(file-append fontconfig "/etc/fonts"))
                  (format port
                          (string-append
                           "export GUIX_GDK_PIXBUF_MODULE_FILES=\""
                           "${GUIX_GDK_PIXBUF_MODULE_FILES:+"
                           "$GUIX_GDK_PIXBUF_MODULE_FILES:}~a\"\n")
                          #$(file-append gdk-pixbuf
                             "/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"))
                  (format port
                          (string-append
                           "export ELECTRON_OZONE_PLATFORM_HINT=\""
                           "${ELECTRON_OZONE_PLATFORM_HINT:-auto}\"\n"))
                  (format port "exec ~a \"$@\"\n"
                          (string-append app "/learnharness"))))
              (chmod wrapper #o555))))))
    (native-inputs (list binutils patchelf tar xz))
    (inputs (append %runtime-packages
                    (list bash-minimal
                          coreutils-minimal
                          xdg-utils
                          libglvnd
                          mesa
                          ;; The lib output supplies libstdc++/libgcc_s for the
                          ;; traced native .node modules.
                          (list gcc "lib"))))
    (supported-systems '("x86_64-linux"))
    (synopsis "AI-assisted learning environment")
    (description
     "LearnHarness is an Electron desktop application that plans and teaches
lessons with an AI agent, keeps a persistent knowledge graph, and supports
provider API keys, subscription logins and custom OpenAI-compatible endpoints.
This package installs the upstream Linux release.")
    (home-page "https://github.com/amosblomqvist/learnharness")
    (license license:agpl3)))
