#ifndef OPENARC_HELPER_FAIRPLAY_BRIDGE_SCRIPT_H_
#define OPENARC_HELPER_FAIRPLAY_BRIDGE_SCRIPT_H_

namespace shared {

// Plays a page's FairPlay audio in Chromium. It runs in the page's main world
// before the page's scripts, on the sites the bridge serves, and asks the
// browser whether the bridge is on; until it answers (3 s at most), key system
// requests wait. When it is on:
//
// - `requestMediaKeySystemAccess` grants FairPlay (`com.apple.fps`) with keys
//   of its own and refuses Widevine and PlayReady, so the player picks FairPlay.
// - A media element with those keys whose source becomes an HLS playlist in a
//   `data:` address with an `skd://` key plays in the browser's native player.
//   The element reports that player's state: time, duration, paused, ended,
//   volume and the usual events, so the page and the sidebar see it play.
// - The native player's license request goes to the page as the session's
//   `message`; the page's own code gets the license and passes it to `update`.
//
// `send` takes one JSON string. The function it returns takes the browser's
// events as JSON strings. Off, the page sees Chromium's own answers.
constexpr char kFairPlayBridgeScript[] = R"JS(
(function (send) {
  'use strict';
  const apply = Reflect.apply;
  const { defineProperty, getOwnPropertyDescriptor } = Object;
  const stringify = JSON.stringify;
  const parse = JSON.parse;
  const NativeProxy = Proxy;
  const setTimer = window.setTimeout.bind(window);
  const setRepeat = window.setInterval.bind(window);
  const clearRepeat = window.clearInterval.bind(window);
  const clock = performance;
  const clockNow = clock.now;
  const now = () => apply(clockNow, clock, []);
  const btoa = window.btoa.bind(window);
  const atob = window.atob.bind(window);
  const post = (message) => send(stringify(message));

  const FAIRPLAY = /^com\.apple\.fps/;
  const OTHER_PROTECTED = /^com\.(widevine|microsoft\.playready)/;
  const PLAYLIST = /^data:application\/(?:vnd\.apple\.mpegurl|x-mpegurl)((?:;[^,]*)?),/i;
  const CONFIG_WAIT_MS = 3000;
  const READY_WAIT_MS = 45000;
  const SEEK_WAIT_MS = 3000;
  const TICK_MS = 250;
  const PART = 30000;

  // Keeps a replaced method looking native to the page.
  const disguise = (native, replacement) => new NativeProxy(native, {
    apply(target, self, args) { return replacement(target, self, args); },
  });

  let enabled = null;
  const waiting = [];
  const configured = () => enabled !== null ? Promise.resolve() : new Promise((resolve) => {
    waiting.push(resolve);
    setTimer(resolve, CONFIG_WAIT_MS);
  });

  const bytesOf = (data) => data instanceof ArrayBuffer ? new Uint8Array(data)
    : ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength) : new Uint8Array(0);
  const toBase64 = (bytes) => {
    let text = '';
    for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(text);
  };
  const fromBase64 = (text) => {
    const binary = atob(text);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  };
  const fire = (target, type) => target.dispatchEvent(new Event(type));

  // MARK: Keys

  let certificate = '';
  const ourKeys = new WeakSet();
  const keysOfMedia = new WeakMap();
  let lastKeyedMedia = null;
  // The session that waits for the native player's license request, and that request.
  let waitingSession = null;
  let licenseRequest = null;
  const sessionTrack = new WeakMap();

  function deliverLicenseRequest() {
    if (!waitingSession || !licenseRequest || sessionTrack.get(waitingSession) !== licenseRequest.generation) return;
    const target = waitingSession;
    const message = licenseRequest.message;
    licenseRequest = null;
    let event;
    try {
      event = new MediaKeyMessageEvent('message', { messageType: 'license-request', message });
    } catch (e) {
      event = new Event('message');
      event.messageType = 'license-request';
      event.message = message;
    }
    target.dispatchEvent(event);
  }

  function createSession() {
    const session = new EventTarget();
    session.sessionId = 'openarc-' + Math.random().toString(36).slice(2);
    session.expiration = NaN;
    session.keyStatuses = new Map();
    let closed;
    session.closed = new Promise((resolve) => { closed = resolve; });
    session.generateRequest = () => {
      sessionTrack.set(session, generation);
      waitingSession = session;
      deliverLicenseRequest();
      return Promise.resolve();
    };
    session.update = (response) => {
      post({ op: 'license', generation: sessionTrack.get(session), ckc: toBase64(bytesOf(response)) });
      session.keyStatuses = new Map([[new Uint8Array(16).buffer, 'usable']]);
      fire(session, 'keystatuseschange');
      return Promise.resolve();
    };
    session.load = () => Promise.resolve(false);
    session.remove = () => Promise.resolve();
    session.close = () => {
      closed();
      return Promise.resolve();
    };
    return session;
  }

  function createKeys() {
    const keys = {
      setServerCertificate(data) {
        const bytes = bytesOf(data);
        if (bytes.length > 0) certificate = toBase64(bytes);
        return Promise.resolve(true);
      },
      createSession,
      getStatusForPolicy: () => Promise.resolve('usable'),
    };
    ourKeys.add(keys);
    return keys;
  }

  const navigatorProto = Navigator.prototype;
  const nativeRequestAccess = navigatorProto.requestMediaKeySystemAccess;
  if (typeof nativeRequestAccess === 'function') {
    navigatorProto.requestMediaKeySystemAccess = disguise(nativeRequestAccess, (target, self, args) => {
      const system = String(args[0] || '');
      if (!FAIRPLAY.test(system) && !OTHER_PROTECTED.test(system)) return apply(target, self, args);
      return configured().then(() => {
        if (enabled !== true) return apply(target, self, args);
        if (!FAIRPLAY.test(system)) {
          throw new DOMException('Unsupported keySystem or supportedConfigurations.', 'NotSupportedError');
        }
        const configuration = (args[1] && args[1][0]) || {};
        return {
          keySystem: system,
          getConfiguration: () => configuration,
          createMediaKeys: () => Promise.resolve(createKeys()),
        };
      });
    });
  }

  const Media = HTMLMediaElement.prototype;
  const mediaKeysProperty = getOwnPropertyDescriptor(Media, 'mediaKeys');
  if (mediaKeysProperty && mediaKeysProperty.get) {
    defineProperty(Media, 'mediaKeys', {
      ...mediaKeysProperty,
      get() { return keysOfMedia.has(this) ? keysOfMedia.get(this) : apply(mediaKeysProperty.get, this, []); },
    });
  }
  if (typeof Media.setMediaKeys === 'function') {
    Media.setMediaKeys = disguise(Media.setMediaKeys, (target, self, args) => {
      if (ourKeys.has(args[0])) {
        keysOfMedia.set(self, args[0]);
        lastKeyedMedia = self;
        return Promise.resolve();
      }
      keysOfMedia.delete(self);
      return apply(target, self, args);
    });
  }
  Media.canPlayType = disguise(Media.canPlayType, (target, self, args) => {
    if (enabled === true && /mpegurl/i.test(String(args[0] || ''))) return 'maybe';
    return apply(target, self, args);
  });

  // MARK: Tracks

  let generation = 0;
  // The element the native player plays for, and its track's state by element.
  let current = null;
  const tracks = new WeakMap();
  let ticker = 0;

  const position = (track) => track.paused || !track.playing ? track.time
    : Math.min(Number.isNaN(track.duration) ? Infinity : track.duration, track.time + (now() - track.stamp) / 1000);
  const ranges = (track) => ({
    length: track.ready ? 1 : 0,
    start: () => 0,
    end: () => (Number.isNaN(track.duration) ? 0 : track.duration),
  });
  const playing = (track) => !track.detached && !track.failed;

  function stopTicking() {
    if (ticker) clearRepeat(ticker);
    ticker = 0;
  }
  function startTicking() {
    if (ticker) return;
    ticker = setRepeat(() => {
      const track = current && tracks.get(current);
      if (track && !track.paused) fire(current, 'timeupdate');
      else stopTicking();
    }, TICK_MS);
  }

  const natives = {};
  function override(name, get, set) {
    const native = getOwnPropertyDescriptor(Media, name);
    if (!native || !native.get) return;
    natives[name] = native;
    defineProperty(Media, name, {
      ...native,
      get() {
        const track = tracks.get(this);
        return track ? get(track) : apply(native.get, this, []);
      },
      set: native.set ? function (value) {
        const track = tracks.get(this);
        if (track && set) set(track, this, value);
        else apply(native.set, this, [value]);
      } : undefined,
    });
  }
  const nativeValue = (element, name, fallback) => {
    try { return apply(natives[name].get, element, []); } catch (e) { return fallback; }
  };

  function seek(track, element, value) {
    const time = +value;
    if (!isFinite(time) || time < 0) return;
    track.time = time;
    track.stamp = now();
    track.ended = false;
    fire(element, 'seeking');
    if (!playing(track)) {
      fire(element, 'seeked');
      fire(element, 'timeupdate');
      return;
    }
    const sequence = ++track.seeks;
    track.seeking = sequence;
    post({ op: 'seek', time, sequence });
    setTimer(() => {
      if (track.seeking === sequence) finishSeek(track, element);
    }, SEEK_WAIT_MS);
  }
  function finishSeek(track, element) {
    track.seeking = 0;
    fire(element, 'seeked');
    fire(element, 'timeupdate');
  }

  override('readyState', (track) => track.ready);
  override('networkState', (track) => (track.ready ? 1 : 2));
  override('duration', (track) => track.duration);
  override('paused', (track) => track.paused);
  override('ended', (track) => track.ended);
  override('error', (track) => track.error);
  override('seeking', (track) => track.seeking !== 0);
  override('buffered', ranges);
  override('seekable', ranges);
  override('webkitAudioDecodedByteCount', (track) => (track.ready ? 1 : 0));
  override('currentTime', position, seek);
  override('volume', (track) => track.volume, (track, element, value) => {
    track.volume = Math.min(Math.max(+value || 0, 0), 1);
    if (playing(track)) post({ op: 'volume', volume: track.volume });
    fire(element, 'volumechange');
  });
  override('muted', (track) => track.muted, (track, element, value) => {
    track.muted = !!value;
    if (playing(track)) post({ op: 'muted', muted: track.muted });
    fire(element, 'volumechange');
  });

  Media.play = disguise(Media.play, (target, self, args) => {
    const track = tracks.get(self);
    if (!track) return apply(target, self, args);
    if (track.failed) return Promise.reject(new DOMException('The element has no supported sources.', 'NotSupportedError'));
    if (track.detached) {
      load(self, track);
      if (track.time > 0) post({ op: 'seek', time: track.time, sequence: ++track.seeks });
    }
    if (track.paused) {
      if (track.ended) seek(track, self, 0);
      track.paused = false;
      track.ended = false;
      track.stamp = now();
      post({ op: 'play' });
      fire(self, 'play');
      startTicking();
    }
    return Promise.resolve();
  });
  Media.pause = disguise(Media.pause, (target, self, args) => {
    const track = tracks.get(self);
    if (!track) return apply(target, self, args);
    if (track.paused) return undefined;
    track.time = position(track);
    track.paused = true;
    track.playing = false;
    post({ op: 'pause' });
    fire(self, 'pause');
    return undefined;
  });
  Media.load = disguise(Media.load, (target, self, args) => (tracks.has(self) ? undefined : apply(target, self, args)));

  function encryptedEvent(skd) {
    const event = new Event('encrypted');
    // The type and data Spotify's player takes from Safari's FairPlay path.
    event.initDataType = 'cbcs';
    event.initData = new TextEncoder().encode(skd);
    return event;
  }

  // A FairPlay HLS playlist set as the source of an element with our keys.
  function bridge(element, value) {
    if (enabled !== true || !element || !keysOfMedia.has(element)) return false;
    const url = String(value);
    const head = url.match(PLAYLIST);
    if (!head) return false;
    let playlist;
    try {
      playlist = /;base64/i.test(head[1]) ? atob(url.slice(head[0].length)) : decodeURIComponent(url.slice(head[0].length));
    } catch (e) {
      return false;
    }
    const skd = (playlist.match(/URI="(skd:\/\/[^"]+)"/) || [])[1];
    if (!/^#EXTM3U/.test(playlist) || !skd || !certificate) return false;
    const previous = tracks.get(element);
    if (current && current !== element) detach(current);
    const track = {
      generation: 0,
      playlist,
      certificate,
      loaded: false,
      detached: false,
      ready: 0,
      time: 0,
      stamp: now(),
      duration: NaN,
      paused: true,
      playing: false,
      ended: false,
      error: null,
      failed: false,
      seeks: 0,
      seeking: 0,
      volume: previous ? previous.volume : nativeValue(element, 'volume', 1),
      muted: previous ? previous.muted : nativeValue(element, 'muted', false),
    };
    tracks.set(element, track);
    stopTicking();
    load(element, track);
    setTimer(() => {
      if (tracks.get(element) === track) element.dispatchEvent(encryptedEvent(skd));
    }, 50);
    return true;
  }

  function load(element, track) {
    const previous = track.generation;
    track.generation = ++generation;
    track.detached = false;
    track.loaded = false;
    if (previous && waitingSession && sessionTrack.get(waitingSession) === previous) {
      sessionTrack.set(waitingSession, track.generation);
    }
    current = element;
    licenseRequest = null;
    const parts = Math.max(1, Math.ceil(track.playlist.length / PART));
    for (let part = 0; part < parts; part++) {
      post({
        op: 'load',
        generation: track.generation,
        part,
        parts,
        playlist: track.playlist.slice(part * PART, (part + 1) * PART),
        certificate: part === 0 ? track.certificate : '',
        volume: track.volume,
        muted: track.muted,
      });
    }
    const loading = track.generation;
    setTimer(() => {
      if (tracks.get(element) === track && track.generation === loading && !track.loaded && !track.detached) {
        fail(element, track);
      }
    }, READY_WAIT_MS);
  }

  // Another element took the native player: this one keeps its place, paused.
  function detach(element) {
    const track = tracks.get(element);
    if (!track) return;
    track.detached = true;
    if (track.paused) return;
    track.time = position(track);
    track.paused = true;
    track.playing = false;
    stopTicking();
    fire(element, 'pause');
  }

  function unbridge(element) {
    if (!element || !tracks.has(element)) return;
    tracks.delete(element);
    if (current === element) {
      current = null;
      licenseRequest = null;
      stopTicking();
      post({ op: 'stop' });
    }
    fire(element, 'emptied');
  }

  function fail(element, track) {
    if (track.failed) return;
    if (current === element && playing(track)) post({ op: 'stop' });
    track.failed = true;
    track.playing = false;
    track.paused = true;
    stopTicking();
    track.error = { code: 3, message: 'Protected playback failed', MEDIA_ERR_ABORTED: 1, MEDIA_ERR_NETWORK: 2,
      MEDIA_ERR_DECODE: 3, MEDIA_ERR_SRC_NOT_SUPPORTED: 4 };
    fire(element, 'error');
  }

  const sourceSrc = getOwnPropertyDescriptor(HTMLSourceElement.prototype, 'src');
  defineProperty(HTMLSourceElement.prototype, 'src', {
    ...sourceSrc,
    set(value) {
      const parent = this.parentElement instanceof HTMLMediaElement ? this.parentElement : null;
      if (bridge(parent || lastKeyedMedia, value)) return;
      unbridge(parent);
      apply(sourceSrc.set, this, [value]);
    },
  });
  const mediaSrc = getOwnPropertyDescriptor(Media, 'src');
  defineProperty(Media, 'src', {
    ...mediaSrc,
    set(value) {
      if (bridge(this, value)) return;
      unbridge(this);
      apply(mediaSrc.set, this, [value]);
    },
  });
  const srcObject = getOwnPropertyDescriptor(Media, 'srcObject');
  if (srcObject && srcObject.set) {
    defineProperty(Media, 'srcObject', {
      ...srcObject,
      set(value) {
        unbridge(this);
        apply(srcObject.set, this, [value]);
      },
    });
  }
  const elementProto = Element.prototype;
  const isSrc = (name) => typeof name === 'string' && name.toLowerCase() === 'src';
  defineProperty(Media, 'setAttribute', {
    ...getOwnPropertyDescriptor(elementProto, 'setAttribute'),
    value: disguise(elementProto.setAttribute, (target, self, args) => {
      if (isSrc(args[0])) {
        if (bridge(self, args[1])) return undefined;
        unbridge(self);
      }
      return apply(target, self, args);
    }),
  });
  defineProperty(Media, 'removeAttribute', {
    ...getOwnPropertyDescriptor(elementProto, 'removeAttribute'),
    value: disguise(elementProto.removeAttribute, (target, self, args) => {
      if (isSrc(args[0])) unbridge(self);
      return apply(target, self, args);
    }),
  });

  window.addEventListener('pagehide', (event) => {
    if (!event.isTrusted || !current) return;
    post({ op: 'stop' });
    detach(current);
  });

  post({ op: 'hello' });

  // MARK: Browser events

  return function receive(json) {
    let message;
    try { message = parse(json); } catch (e) { return; }
    if (message.event === 'config') {
      enabled = message.on === true;
      for (const resolve of waiting.splice(0)) resolve();
      return;
    }
    const element = current;
    const track = element && tracks.get(element);
    if (!track || message.generation !== track.generation || track.failed) return;
    switch (message.event) {
      case 'request':
        licenseRequest = { generation: message.generation, message: fromBase64(message.spc).buffer };
        deliverLicenseRequest();
        break;
      case 'ready':
        track.loaded = true;
        track.duration = message.duration > 0 ? message.duration : NaN;
        track.ready = 4;
        for (const type of ['loadedmetadata', 'durationchange', 'loadeddata', 'canplay', 'canplaythrough']) fire(element, type);
        break;
      case 'position': {
        if (message.sequence < track.seeks) return;
        track.time = message.time;
        track.stamp = now();
        if (track.seeking) finishSeek(track, element);
        const was = track.playing;
        track.playing = !!message.playing && !track.paused;
        if (track.playing && !was) fire(element, 'playing');
        else if (was && !track.playing && !track.paused) fire(element, 'waiting');
        break;
      }
      case 'ended':
        if (!Number.isNaN(track.duration)) track.time = track.duration;
        track.playing = false;
        track.paused = true;
        track.ended = true;
        stopTicking();
        fire(element, 'timeupdate');
        fire(element, 'pause');
        fire(element, 'ended');
        break;
      case 'failed':
        fail(element, track);
        break;
      default:
        break;
    }
  };
})
)JS";

}  // namespace shared

#endif  // OPENARC_HELPER_FAIRPLAY_BRIDGE_SCRIPT_H_
