#ifndef OPENARC_HELPER_PROTECTED_VIDEO_BRIDGE_SCRIPT_H_
#define OPENARC_HELPER_PROTECTED_VIDEO_BRIDGE_SCRIPT_H_

namespace shared {

// Plays a video site's protected video in Chromium with FairPlay. It runs in the
// main world of the site's top document, before the site's scripts, while the
// bridge is on. The site sees Safari: Safari's user agent, FairPlay granted and
// Widevine refused. Its player then runs its usual Media Source and EME code
// against this script:
//
// - `MediaSource` and `SourceBuffer` are the script's own. Appended fragments go
//   to the browser, whose native player parses, keeps and plays them; buffered
//   ranges and update events follow the browser's answers.
// - A video or audio element whose source is such a MediaSource reports the
//   native player's state: time, duration, paused, seeking, ready state, size,
//   volume, rate and the usual events. The element's place on the page goes to
//   the browser, which draws the video there.
// - Key sessions pass the native player's license requests to the page as
//   `message` events, and the page's licenses back through `update`. Init data
//   the native parser finds in a fragment reaches the element as `encrypted`.
//
// `send(json, buffer)` takes a JSON string and, for fragments, an ArrayBuffer.
// The function it returns takes the browser's events as JSON strings.
constexpr char kProtectedVideoBridgeScript[] = R"JS(
(function (send, userAgent) {
  'use strict';
  const apply = Reflect.apply;
  const { defineProperty, getOwnPropertyDescriptor } = Object;
  const stringify = JSON.stringify;
  const parse = JSON.parse;
  const NativeProxy = Proxy;
  const setTimer = window.setTimeout.bind(window);
  const clearTimer = window.clearTimeout.bind(window);
  const setRepeat = window.setInterval.bind(window);
  const clearRepeat = window.clearInterval.bind(window);
  const clock = performance;
  const clockNow = clock.now;
  const now = () => apply(clockNow, clock, []);
  const btoa = window.btoa.bind(window);
  const atob = window.atob.bind(window);
  const post = (message, buffer) => (buffer ? send(stringify(message), buffer) : send(stringify(message)));
  const disguise = (native, replacement) => new NativeProxy(native, {
    apply(target, self, args) { return replacement(target, self, args); },
  });
  const fire = (target, type) => target.dispatchEvent(new Event(type));
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
  const DOMError = (name, message) => new DOMException(message, name);

  // MARK: Safari

  const navigatorProto = Navigator.prototype;
  const getter = (object, name, value) => defineProperty(object, name, { get: () => value, configurable: true, enumerable: true });
  getter(navigatorProto, 'userAgent', userAgent);
  getter(navigatorProto, 'appVersion', userAgent.replace(/^Mozilla\//, ''));
  getter(navigatorProto, 'vendor', 'Apple Computer, Inc.');
  getter(navigatorProto, 'userAgentData', undefined);

  // MARK: Keys

  const FAIRPLAY = /^com\.apple\.fps/;
  const OTHER_PROTECTED = /^com\.(widevine|microsoft\.playready)/;
  let nextKeys = 0;
  let nextSession = 0;
  const sessions = new Map();
  const ourKeys = new WeakMap();

  function createSession(keysID, keySystem) {
    const session = new EventTarget();
    const id = ++nextSession;
    sessions.set(id, session);
    session.sessionId = 'openarc-' + id;
    session.expiration = NaN;
    session.keyStatuses = new Map();
    let closed;
    session.closed = new Promise((resolve) => { closed = resolve; });
    session.generateRequest = (type, initData) => {
      post({ op: 'keyRequest', keys: keysID, session: id, keySystem, type: String(type), data: toBase64(bytesOf(initData)) });
      return Promise.resolve();
    };
    session.update = (response) => {
      post({ op: 'keyUpdate', session: id, data: toBase64(bytesOf(response)) });
      return Promise.resolve();
    };
    session.load = () => Promise.resolve(false);
    session.remove = () => Promise.resolve();
    session.close = () => {
      post({ op: 'keyClose', session: id });
      sessions.delete(id);
      closed();
      return Promise.resolve();
    };
    return session;
  }

  function createKeys(keySystem) {
    const id = ++nextKeys;
    const keys = {
      setServerCertificate(data) {
        const bytes = bytesOf(data);
        if (bytes.length > 0) post({ op: 'certificate', keys: id, data: toBase64(bytes) });
        return Promise.resolve(true);
      },
      createSession: () => createSession(id, keySystem),
      getStatusForPolicy: () => Promise.resolve('usable'),
    };
    ourKeys.set(keys, id);
    return keys;
  }

  const nativeRequestAccess = navigatorProto.requestMediaKeySystemAccess;
  if (typeof nativeRequestAccess === 'function') {
    navigatorProto.requestMediaKeySystemAccess = disguise(nativeRequestAccess, (target, self, args) => {
      const system = String(args[0] || '');
      if (OTHER_PROTECTED.test(system)) {
        return Promise.reject(DOMError('NotSupportedError', 'Unsupported keySystem or supportedConfigurations.'));
      }
      if (!FAIRPLAY.test(system)) return apply(target, self, args);
      const configuration = (args[1] && args[1][0]) || {};
      return Promise.resolve({
        keySystem: system,
        getConfiguration: () => configuration,
        createMediaKeys: () => Promise.resolve(createKeys(system)),
      });
    });
  }

  // MARK: Media Source

  const NativeMediaSource = window.MediaSource;
  const SUPPORTED = /^(video|audio)\/mp4/i;
  const CODECS = /(avc1|avc3|hvc1|hev1|dvh1|dvhe|mp4a|ec-3|ac-3|opus|flac|alac)/i;
  const isTypeSupported = (type) => {
    const text = String(type || '');
    if (!SUPPORTED.test(text)) return false;
    const codecs = text.match(/codecs\s*=\s*"?([^";]+)"?/i);
    return !codecs || codecs[1].split(',').every((codec) => CODECS.test(codec.trim()));
  };
  let nextMedia = 0;
  let nextBuffer = 0;
  const sourcesByURL = new Map();
  const players = new WeakMap();
  const playersByID = new Map();

  const ranges = (list) => ({
    length: list.length,
    start(index) {
      if (index < 0 || index >= list.length) throw DOMError('IndexSizeError', 'Index out of range.');
      return list[index][0];
    },
    end(index) {
      if (index < 0 || index >= list.length) throw DOMError('IndexSizeError', 'Index out of range.');
      return list[index][1];
    },
  });
  const intersect = (a, b) => {
    const out = [];
    for (const [s1, e1] of a) for (const [s2, e2] of b) {
      const s = Math.max(s1, s2), e = Math.min(e1, e2);
      if (e > s) out.push([s, e]);
    }
    return out.sort((x, y) => x[0] - y[0]);
  };

  class OpenArcSourceBuffer extends EventTarget {
    constructor(source, mime) {
      super();
      this._source = source;
      this._id = ++nextBuffer;
      this._mime = mime;
      this._ranges = [];
      this._updating = false;
      this._queue = [];
      this._sequence = 0;
      this.mode = 'segments';
      this.timestampOffset = 0;
      this.appendWindowStart = 0;
      this.appendWindowEnd = Infinity;
      this.audioTracks = [];
      this.videoTracks = [];
      this.textTracks = [];
      this.onupdatestart = this.onupdate = this.onupdateend = this.onerror = this.onabort = null;
    }
    get updating() { return this._updating; }
    get buffered() { return ranges(this._ranges); }
    _fire(type) {
      fire(this, type);
      const handler = this['on' + type];
      if (typeof handler === 'function') handler.call(this, new Event(type));
    }
    _start(message, buffer) {
      if (this._source.readyState === 'closed') throw DOMError('InvalidStateError', 'The MediaSource is closed.');
      if (this._updating) throw DOMError('InvalidStateError', 'The SourceBuffer is updating.');
      if (this._source.readyState === 'ended') this._source._reopen();
      this._updating = true;
      const sequence = ++this._sequence;
      this._fire('updatestart');
      post({ ...message, media: this._source._media, buffer: this._id, sequence }, buffer);
    }
    appendBuffer(data) {
      const bytes = bytesOf(data);
      const copy = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
      this._start({
        op: 'append',
        offset: +this.timestampOffset || 0,
        windowStart: +this.appendWindowStart || 0,
        windowEnd: isFinite(this.appendWindowEnd) ? +this.appendWindowEnd : -1,
      }, copy);
    }
    remove(start, end) {
      this._start({ op: 'remove', start: +start, end: isFinite(end) ? +end : -1 });
    }
    abort() {
      if (this._updating) {
        this._updating = false;
        this._sequence++;
        this._fire('abort');
        this._fire('updateend');
      }
      post({ op: 'abort', media: this._source._media, buffer: this._id });
    }
    changeType(mime) {
      this._mime = String(mime);
      post({ op: 'changeType', media: this._source._media, buffer: this._id, mime: this._mime });
    }
    _finish(message) {
      if (message.sequence !== this._sequence || !this._updating) return;
      this._ranges = message.ranges || [];
      this._updating = false;
      if (message.ok === false) {
        this._fire('error');
      } else {
        this._fire('update');
      }
      this._fire('updateend');
      this._source._buffersChanged();
    }
  }

  class OpenArcMediaSource extends EventTarget {
    constructor() {
      super();
      this._media = ++nextMedia;
      this._readyState = 'closed';
      this._duration = NaN;
      this._buffers = [];
      this._element = null;
      this.onsourceopen = this.onsourceended = this.onsourceclose = null;
    }
    static isTypeSupported(type) { return isTypeSupported(type); }
    get readyState() { return this._readyState; }
    get sourceBuffers() { return this._list(this._buffers); }
    get activeSourceBuffers() { return this._list(this._buffers); }
    get duration() { return this._duration; }
    set duration(value) {
      const duration = +value;
      if (Number.isNaN(duration) || duration < 0) throw new TypeError('Invalid duration.');
      if (this._readyState !== 'open') throw DOMError('InvalidStateError', 'The MediaSource is not open.');
      this._duration = duration;
      post({ op: 'duration', media: this._media, duration: isFinite(duration) ? duration : -1 });
      if (this._element) fire(this._element, 'durationchange');
    }
    _list(array) {
      const list = Object.assign(new EventTarget(), { length: array.length });
      array.forEach((buffer, index) => { list[index] = buffer; });
      list[Symbol.iterator] = function* () { yield* array; };
      return list;
    }
    _fire(type) {
      fire(this, type);
      const handler = this['on' + type];
      if (typeof handler === 'function') handler.call(this, new Event(type));
    }
    addSourceBuffer(mime) {
      if (!isTypeSupported(mime)) throw DOMError('NotSupportedError', 'The type provided is unsupported.');
      if (this._readyState !== 'open') throw DOMError('InvalidStateError', 'The MediaSource is not open.');
      const buffer = new OpenArcSourceBuffer(this, String(mime));
      this._buffers.push(buffer);
      post({ op: 'addBuffer', media: this._media, buffer: buffer._id, mime: buffer._mime });
      return buffer;
    }
    removeSourceBuffer(buffer) {
      const index = this._buffers.indexOf(buffer);
      if (index < 0) throw DOMError('NotFoundError', 'The SourceBuffer is not in this MediaSource.');
      this._buffers.splice(index, 1);
      post({ op: 'removeBuffer', media: this._media, buffer: buffer._id });
    }
    endOfStream(error) {
      if (this._readyState !== 'open') throw DOMError('InvalidStateError', 'The MediaSource is not open.');
      this._readyState = 'ended';
      post({ op: 'endOfStream', media: this._media, error: error ? String(error) : '' });
      this._fire('sourceended');
    }
    _reopen() {
      this._readyState = 'open';
      post({ op: 'reopen', media: this._media });
      this._fire('sourceopen');
    }
    setLiveSeekableRange() {}
    clearLiveSeekableRange() {}
    _buffersChanged() {
      const player = this._element && players.get(this._element);
      if (player) player.buffersChanged();
    }
    _buffered() {
      if (this._buffers.length === 0) return [];
      return this._buffers.map((buffer) => buffer._ranges).reduce(intersect);
    }
  }
  defineProperty(OpenArcMediaSource, 'name', { value: 'MediaSource' });
  defineProperty(OpenArcSourceBuffer, 'name', { value: 'SourceBuffer' });
  window.MediaSource = OpenArcMediaSource;
  window.SourceBuffer = OpenArcSourceBuffer;
  if ('ManagedMediaSource' in window) window.ManagedMediaSource = undefined;
  if ('WebKitMediaSource' in window) window.WebKitMediaSource = undefined;

  const nativeCreateObjectURL = URL.createObjectURL;
  URL.createObjectURL = disguise(nativeCreateObjectURL, (target, self, args) => {
    if (args[0] instanceof OpenArcMediaSource) {
      const url = apply(target, self, [new Blob()]);
      sourcesByURL.set(url, args[0]);
      return url;
    }
    return apply(target, self, args);
  });
  const nativeRevokeObjectURL = URL.revokeObjectURL;
  URL.revokeObjectURL = disguise(nativeRevokeObjectURL, (target, self, args) => {
    sourcesByURL.delete(String(args[0]));
    return apply(target, self, args);
  });

  // MARK: Media elements

  const Media = HTMLMediaElement.prototype;
  const HAVE_NOTHING = 0, HAVE_METADATA = 1, HAVE_FUTURE_DATA = 3, HAVE_ENOUGH_DATA = 4;

  class Player {
    constructor(element, source) {
      this.element = element;
      this.source = source;
      this.media = source._media;
      this.time = 0;
      this.stamp = now();
      this.running = false;
      this.paused = true;
      this.ended = false;
      this.seeking = 0;
      this.seeks = 0;
      this.rate = 1;
      this.volume = nativeValue(element, 'volume', 1);
      this.muted = nativeValue(element, 'muted', false);
      this.readyState = HAVE_NOTHING;
      this.width = 0;
      this.height = 0;
      this.error = null;
      this.frames = 0;
      this.dropped = 0;
      this.ticker = 0;
      this.rectKey = '';
      this.placer = 0;
    }
    position() {
      const end = this.duration();
      const limit = isFinite(end) ? end : Infinity;
      if (this.paused || !this.running || this.seeking) return Math.min(limit, this.time);
      const elapsed = (now() - this.stamp) / 1000 * this.rate;
      return Math.min(limit, this.time + elapsed);
    }
    duration() {
      return this.source._duration;
    }
    buffered() {
      return this.source._buffered();
    }
    bufferedAhead(time) {
      for (const [start, end] of this.buffered()) if (time >= start - 0.1 && time < end) return end - time;
      return 0;
    }
    buffersChanged() {
      const time = this.position();
      let state = this.readyState;
      if (state >= HAVE_METADATA) {
        const ahead = this.bufferedAhead(time);
        const atEnd = this.source._readyState === 'ended' && ahead > 0;
        state = ahead >= 2 || atEnd ? HAVE_ENOUGH_DATA : ahead > 0.1 ? HAVE_FUTURE_DATA : HAVE_METADATA;
      }
      this.setReadyState(state);
    }
    setReadyState(state) {
      const previous = this.readyState;
      if (state === previous) return;
      this.readyState = state;
      const element = this.element;
      if (previous < HAVE_METADATA && state >= HAVE_METADATA) {
        fire(element, 'loadedmetadata');
      }
      if (previous < 2 && state >= 2) fire(element, 'loadeddata');
      if (previous < HAVE_FUTURE_DATA && state >= HAVE_FUTURE_DATA) {
        fire(element, 'canplay');
        if (!this.paused) fire(element, 'playing');
      }
      if (previous < HAVE_ENOUGH_DATA && state >= HAVE_ENOUGH_DATA) fire(element, 'canplaythrough');
      if (previous >= HAVE_FUTURE_DATA && state < HAVE_FUTURE_DATA && !this.paused) fire(element, 'waiting');
    }
    startTicking() {
      if (this.ticker) return;
      this.ticker = setRepeat(() => {
        if (this.paused) {
          clearRepeat(this.ticker);
          this.ticker = 0;
          return;
        }
        fire(this.element, 'timeupdate');
      }, 250);
    }
    place() {
      const element = this.element;
      const box = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      const visible = element.isConnected && box.width > 1 && box.height > 1 && style.visibility !== 'hidden' &&
        style.display !== 'none' && Number(style.opacity) > 0.01;
      const message = {
        op: 'rect',
        media: this.media,
        x: box.left,
        y: box.top,
        width: box.width,
        height: box.height,
        visible,
        dpr: devicePixelRatio,
        fit: style.objectFit || 'contain',
      };
      const key = stringify(message);
      if (key === this.rectKey) return;
      this.rectKey = key;
      post(message);
    }
    startPlacing() {
      if (this.placer) return;
      const loop = () => {
        this.placer = 0;
        if (playersByID.get(this.media) !== this) return;
        this.place();
        this.placer = setTimer(loop, 200);
      };
      loop();
    }
  }

  const natives = {};
  function override(name, get, set) {
    const native = getOwnPropertyDescriptor(Media, name) || getOwnPropertyDescriptor(HTMLVideoElement.prototype, name);
    if (!native || !native.get) return;
    natives[name] = native;
    const owner = getOwnPropertyDescriptor(Media, name) ? Media : HTMLVideoElement.prototype;
    defineProperty(owner, name, {
      ...native,
      get() {
        const player = players.get(this);
        return player ? get(player) : apply(native.get, this, []);
      },
      set: native.set ? function (value) {
        const player = players.get(this);
        if (player && set) set(player, this, value);
        else apply(native.set, this, [value]);
      } : undefined,
    });
  }
  function nativeValue(element, name, fallback) {
    try { return apply(natives[name].get, element, []); } catch (e) { return fallback; }
  }

  function seek(player, value) {
    const time = +value;
    if (!isFinite(time) || time < 0) return;
    player.time = time;
    player.stamp = now();
    player.ended = false;
    const sequence = ++player.seeks;
    player.seeking = sequence;
    post({ op: 'seek', media: player.media, time, sequence });
    fire(player.element, 'seeking');
    fire(player.element, 'timeupdate');
    player.buffersChanged();
  }

  override('currentTime', (player) => player.position(), (player, element, value) => seek(player, value));
  override('duration', (player) => player.duration());
  override('paused', (player) => player.paused);
  override('ended', (player) => player.ended);
  override('seeking', (player) => player.seeking !== 0);
  override('readyState', (player) => player.readyState);
  override('networkState', () => 2);
  override('error', (player) => player.error);
  override('buffered', (player) => ranges(player.buffered()));
  override('seekable', (player) => ranges(isFinite(player.duration()) ? [[0, player.duration()]] : player.buffered()));
  override('played', () => ranges([]));
  override('videoWidth', (player) => player.width);
  override('videoHeight', (player) => player.height);
  override('playbackRate', (player) => player.rate, (player, element, value) => {
    const rate = +value;
    if (!isFinite(rate)) return;
    player.time = player.position();
    player.stamp = now();
    player.rate = rate;
    post({ op: 'rate', media: player.media, rate });
    fire(element, 'ratechange');
  });
  override('volume', (player) => player.volume, (player, element, value) => {
    player.volume = Math.min(Math.max(+value || 0, 0), 1);
    post({ op: 'volume', media: player.media, volume: player.volume, muted: player.muted });
    fire(element, 'volumechange');
  });
  override('muted', (player) => player.muted, (player, element, value) => {
    player.muted = !!value;
    post({ op: 'volume', media: player.media, volume: player.volume, muted: player.muted });
    fire(element, 'volumechange');
  });
  override('webkitDecodedFrameCount', (player) => player.frames);
  // The sidebar's media observer counts decoded audio to tell sound from silence.
  override('webkitAudioDecodedByteCount', (player) => (player.readyState >= 2 && !player.muted ? 1 : 0));
  override('webkitDroppedFrameCount', (player) => player.dropped);

  if (typeof HTMLVideoElement.prototype.getVideoPlaybackQuality === 'function') {
    HTMLVideoElement.prototype.getVideoPlaybackQuality = disguise(
      HTMLVideoElement.prototype.getVideoPlaybackQuality,
      (target, self, args) => {
        const player = players.get(self);
        if (!player) return apply(target, self, args);
        return { creationTime: now(), totalVideoFrames: player.frames, droppedVideoFrames: player.dropped,
          corruptedVideoFrames: 0 };
      },
    );
  }
  if (typeof HTMLVideoElement.prototype.requestPictureInPicture === 'function') {
    HTMLVideoElement.prototype.requestPictureInPicture = disguise(
      HTMLVideoElement.prototype.requestPictureInPicture,
      (target, self, args) => (players.has(self)
        ? Promise.reject(DOMError('NotSupportedError', 'Picture in Picture is not available for this video.'))
        : apply(target, self, args)),
    );
  }

  const mediaKeysProperty = getOwnPropertyDescriptor(Media, 'mediaKeys');
  const keysOfMedia = new WeakMap();
  if (mediaKeysProperty && mediaKeysProperty.get) {
    defineProperty(Media, 'mediaKeys', {
      ...mediaKeysProperty,
      get() { return keysOfMedia.has(this) ? keysOfMedia.get(this) : apply(mediaKeysProperty.get, this, []); },
    });
  }
  if (typeof Media.setMediaKeys === 'function') {
    Media.setMediaKeys = disguise(Media.setMediaKeys, (target, self, args) => {
      const keys = args[0];
      if (keys && ourKeys.has(keys)) {
        keysOfMedia.set(self, keys);
        const player = players.get(self);
        if (player) post({ op: 'keys', media: player.media, keys: ourKeys.get(keys) });
        return Promise.resolve();
      }
      keysOfMedia.delete(self);
      if (keys === null) return Promise.resolve();
      return apply(target, self, args);
    });
  }

  Media.canPlayType = disguise(Media.canPlayType, (target, self, args) => {
    const type = String(args[0] || '');
    if (SUPPORTED.test(type) && isTypeSupported(type)) return 'probably';
    return apply(target, self, args);
  });

  Media.play = disguise(Media.play, (target, self, args) => {
    const player = players.get(self);
    if (!player) return apply(target, self, args);
    if (player.paused) {
      if (player.ended) seek(player, 0);
      player.paused = false;
      player.ended = false;
      player.stamp = now();
      post({ op: 'play', media: player.media });
      fire(self, 'play');
      if (player.readyState >= HAVE_FUTURE_DATA) fire(self, 'playing');
      else fire(self, 'waiting');
      player.startTicking();
    }
    return Promise.resolve();
  });
  Media.pause = disguise(Media.pause, (target, self, args) => {
    const player = players.get(self);
    if (!player) return apply(target, self, args);
    if (player.paused) return undefined;
    player.time = player.position();
    player.stamp = now();
    player.paused = true;
    post({ op: 'pause', media: player.media });
    fire(self, 'timeupdate');
    fire(self, 'pause');
    return undefined;
  });
  Media.load = disguise(Media.load, (target, self, args) => {
    if (players.has(self)) detach(self);
    return apply(target, self, args);
  });

  function attach(element, source) {
    if (players.has(element)) detach(element);
    const player = new Player(element, source);
    players.set(element, player);
    playersByID.set(player.media, player);
    source._element = element;
    source._readyState = 'open';
    const keys = keysOfMedia.get(element);
    post({
      op: 'attach',
      media: player.media,
      keys: keys ? ourKeys.get(keys) : 0,
      volume: player.volume,
      muted: player.muted,
      autoplay: !!element.autoplay,
    });
    player.startPlacing();
    fire(element, 'emptied');
    fire(element, 'loadstart');
    setTimer(() => {
      if (source._element === element) source._fire('sourceopen');
    }, 0);
    if (element.autoplay) setTimer(() => element.play(), 0);
  }

  function detach(element) {
    const player = players.get(element);
    if (!player) return;
    players.delete(element);
    playersByID.delete(player.media);
    if (player.ticker) clearRepeat(player.ticker);
    if (player.placer) clearTimer(player.placer);
    player.source._element = null;
    player.source._readyState = 'closed';
    player.source._fire('sourceclose');
    post({ op: 'detach', media: player.media });
  }

  const mediaSrc = getOwnPropertyDescriptor(Media, 'src');
  const sourceOf = (value) => sourcesByURL.get(String(value));
  defineProperty(Media, 'src', {
    ...mediaSrc,
    get() {
      const player = players.get(this);
      return player ? player.url : apply(mediaSrc.get, this, []);
    },
    set(value) {
      const source = sourceOf(value);
      if (source) {
        attach(this, source);
        players.get(this).url = String(value);
        return;
      }
      if (players.has(this)) detach(this);
      apply(mediaSrc.set, this, [value]);
    },
  });
  const srcObject = getOwnPropertyDescriptor(Media, 'srcObject');
  if (srcObject && srcObject.set) {
    defineProperty(Media, 'srcObject', {
      ...srcObject,
      get() {
        const player = players.get(this);
        return player && player.byObject ? player.source : apply(srcObject.get, this, []);
      },
      set(value) {
        if (value instanceof OpenArcMediaSource) {
          attach(this, value);
          players.get(this).byObject = true;
          return;
        }
        if (players.has(this)) detach(this);
        apply(srcObject.set, this, [value]);
      },
    });
  }
  const currentSrc = getOwnPropertyDescriptor(Media, 'currentSrc');
  if (currentSrc && currentSrc.get) {
    defineProperty(Media, 'currentSrc', {
      ...currentSrc,
      get() {
        const player = players.get(this);
        return player ? player.url || '' : apply(currentSrc.get, this, []);
      },
    });
  }
  const elementProto = Element.prototype;
  const isSrc = (name) => typeof name === 'string' && name.toLowerCase() === 'src';
  defineProperty(Media, 'setAttribute', {
    ...getOwnPropertyDescriptor(elementProto, 'setAttribute'),
    value: disguise(elementProto.setAttribute, (target, self, args) => {
      if (isSrc(args[0]) && sourceOf(args[1])) {
        self.src = args[1];
        return undefined;
      }
      if (isSrc(args[0]) && players.has(self)) detach(self);
      return apply(target, self, args);
    }),
  });
  defineProperty(Media, 'removeAttribute', {
    ...getOwnPropertyDescriptor(elementProto, 'removeAttribute'),
    value: disguise(elementProto.removeAttribute, (target, self, args) => {
      if (isSrc(args[0]) && players.has(self)) detach(self);
      return apply(target, self, args);
    }),
  });

  window.addEventListener('pagehide', (event) => {
    if (!event.isTrusted) return;
    post({ op: 'reset' });
  });
  post({ op: 'reset' });

  // MARK: Browser events

  return function receive(json) {
    let message;
    try { message = parse(json); } catch (e) { return; }
    if (message.event === 'message' || message.event === 'keys') {
      const session = sessions.get(message.session);
      if (!session) return;
      if (message.event === 'message') {
        const data = fromBase64(message.data).buffer;
        let event;
        try {
          event = new MediaKeyMessageEvent('message', { messageType: 'license-request', message: data });
        } catch (e) {
          event = new Event('message');
          event.messageType = 'license-request';
          event.message = data;
        }
        session.dispatchEvent(event);
      } else {
        const statuses = new Map();
        for (const id of message.keyIDs || []) statuses.set(fromBase64(id).buffer, message.ok ? 'usable' : 'internal-error');
        session.keyStatuses = statuses;
        fire(session, 'keystatuseschange');
      }
      return;
    }
    const player = playersByID.get(message.media);
    if (!player) return;
    const element = player.element;
    switch (message.event) {
      case 'appended':
      case 'removed': {
        const buffer = player.source._buffers.find((candidate) => candidate._id === message.buffer);
        if (buffer) buffer._finish(message);
        break;
      }
      case 'metadata':
        if (message.width > 0 && (message.width !== player.width || message.height !== player.height)) {
          const resized = player.width !== 0;
          player.width = message.width;
          player.height = message.height;
          if (resized) fire(element, 'resize');
        }
        if (Number.isNaN(player.source._duration) && message.duration > 0) {
          player.source._duration = message.duration;
          fire(element, 'durationchange');
        }
        if (player.readyState < HAVE_METADATA) player.setReadyState(HAVE_METADATA);
        player.buffersChanged();
        break;
      case 'encrypted': {
        const event = new Event('encrypted');
        event.initDataType = message.type;
        event.initData = fromBase64(message.data).buffer;
        element.dispatchEvent(event);
        break;
      }
      case 'time': {
        if (message.sequence < player.seeks) return;
        player.time = message.time;
        player.stamp = now();
        player.running = !!message.running;
        player.frames = message.frames || player.frames;
        player.dropped = message.dropped || player.dropped;
        if (player.seeking && message.sequence === player.seeks && message.seeked) {
          player.seeking = 0;
          fire(element, 'seeked');
          fire(element, 'timeupdate');
        }
        player.buffersChanged();
        break;
      }
      case 'ended':
        player.time = message.time;
        player.stamp = now();
        player.paused = true;
        player.ended = true;
        player.running = false;
        fire(element, 'timeupdate');
        fire(element, 'pause');
        fire(element, 'ended');
        break;
      case 'error':
        player.error = { code: 3, message: String(message.message || 'Playback failed'), MEDIA_ERR_ABORTED: 1,
          MEDIA_ERR_NETWORK: 2, MEDIA_ERR_DECODE: 3, MEDIA_ERR_SRC_NOT_SUPPORTED: 4 };
        player.paused = true;
        fire(element, 'error');
        break;
      default:
        break;
    }
  };
})
)JS";

}  // namespace shared

#endif  // OPENARC_HELPER_PROTECTED_VIDEO_BRIDGE_SCRIPT_H_
