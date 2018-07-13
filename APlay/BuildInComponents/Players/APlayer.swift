//
//  APlayer.swift
//  APlay
//
//  Created by lincoln on 2018/6/29.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

import AVFoundation

@available(iOS 11.0, *)
final class APlayer: PlayerCompatible {
    var readClosure: (UInt32, UnsafeMutablePointer<UInt8>) -> (UInt32, Bool) = { _, _ in (0, false) }

    var eventPipeline: Delegated<Player.Event, Void> = Delegated<Player.Event, Void>()

    var startTime: Float = 0 {
        didSet {
            _stateQueue.async(flags: .barrier) { self._progress = 0 }
        }
    }

    fileprivate lazy var _progress: Float = 0
    private lazy var _volume: Float = 1
    private lazy var _isConnected = false

    private(set) lazy var asbd = AudioStreamBasicDescription()

    private(set) var state: Player.State {
        get { return _stateQueue.sync { _state } }
        set {
            _stateQueue.async(flags: .barrier) {
                self._state = newValue
                self.eventPipeline.call(.state(newValue))
            }
        }
    }

    private lazy var _state: Player.State = .idle
    private lazy var _stateQueue = DispatchQueue(concurrentName: "AUPlayer.state")

    private lazy var _playbackTimer: GCDTimer = {
        GCDTimer(interval: .seconds(1), callback: { [weak self] _ in
            guard let sself = self else { return }
            sself.eventPipeline.call(.playback(sself.currentTime()))
        })
    }()

    private lazy var _buffers: UnsafeMutablePointer<UInt8> = {
        let size = Player.minimumBufferSize
        let b = malloc(size).assumingMemoryBound(to: UInt8.self)
        return b
    }()

    private lazy var audioBufferList: AudioBufferList = {
        let buf = AudioBuffer()
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: buf)
        return list
    }()

    private var _player: AudioUnit? = {
        #if os(OSX)
            let subType = kAudioUnitSubType_DefaultOutput
        #else
            let subType = kAudioUnitSubType_RemoteIO
        #endif
        var player: AudioUnit?
        var componentDesc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: subType, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let audioComponent = AudioComponentFindNext(nil, &componentDesc) else { fatalError("player create failure") }
        AudioComponentInstanceNew(audioComponent, &player).check()
        return player
    }()

    private let _engine = AVAudioEngine()
    /// <https://baike.baidu.com/item/EQ均衡器>
    private let _eq = AVAudioUnitEQ()
    fileprivate var _renderBlock: AVAudioEngineManualRenderingBlock?

    private unowned let _config: ConfigurationCompatible

    deinit {
        debug_log("\(self) \(#function)")
    }

    init(config: ConfigurationCompatible) {
        _config = config
        _engine.attach(_eq)
    }
}

// MARK: - Create Player

@available(iOS 11.0, *)
private extension APlayer {
    private func updatePlayerConfig() throws {
        guard let unit = _player else { return }
        let s = MemoryLayout.size(ofValue: asbd)
        // set stream format for input bus
        try AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, Player.Bus.output, &asbd, UInt32(s)).throwCheck()

        let fSize = MemoryLayout.size(ofValue: Player.maxFramesPerSlice)
        try AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &Player.maxFramesPerSlice, UInt32(fSize)).throwCheck()
        // render callback
        let pointer = UnsafeMutableRawPointer.from(object: self)
        var callbackStruct = AURenderCallbackStruct(inputProc: renderCallback, inputProcRefCon: pointer)
        let callbackSize = MemoryLayout.size(ofValue: callbackStruct)
        try AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                 kAudioUnitScope_Output, Player.Bus.output, &callbackStruct,
                                 UInt32(callbackSize)).throwCheck()
    }
}

// MARK: - PlayerCompatible

@available(iOS 11.0, *)
extension APlayer {
    func destroy() {
        _engine.stop()
        _playbackTimer.invalidate()
        pause()
        readClosure = { _, _ in (0, false) }
        eventPipeline.removeDelegate()
    }

    func pause() {
        guard state == .running, let unit = _player else { return }
        AudioOutputUnitStop(unit).check()
        state = .paused
        _playbackTimer.pause()
    }

    func resume() {
        guard state != .running, let unit = _player else { return }
        do {
            try AudioOutputUnitStart(unit).throwCheck()
            state = .running
            _config.startBackgroundTask(isToDownloadImage: false)
            _playbackTimer.resume()
        } catch {
            state = .idle
            debug_log(error.localizedDescription)
        }
    }

    func toggle() {
        state == .paused ? resume() : pause()
    }

    func currentTime() -> Float {
        return _stateQueue.sync { _progress / Float(asbd.mSampleRate) + startTime }
    }

    var volume: Float {
        get { return _volume }
        set {
            _volume = newValue
            #if os(iOS)
                if let unit = _player {
                    AudioUnitSetParameter(unit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, _volume, 0)
                }
            #else
                if let unit = _player {
                    AudioUnitSetParameter(unit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, _volume, 0)
                }
            #endif
        }
    }

    func setup(_ value: AudioStreamBasicDescription) {
        do {
            asbd = value
            try updatePlayerConfig()
            let format = AVAudioFormat(streamDescription: &asbd)!
            _engine.stop()
            try _engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: Player.maxFramesPerSlice)
            _renderBlock = _engine.manualRenderingBlock

            _engine.inputNode.setManualRenderingInputPCMFormat(format) { [weak self] (frameCount) -> UnsafePointer<AudioBufferList>? in
                guard let sself = self else { return nil }
                let bytesPerFrame = sself.asbd.mBytesPerFrame
                let size = bytesPerFrame * frameCount

                let (readSize, _) = sself.readClosure(size, sself._buffers)
                sself.audioBufferList.mBuffers.mData = UnsafeMutableRawPointer(sself._buffers)
                sself.audioBufferList.mBuffers.mNumberChannels = sself.asbd.mChannelsPerFrame
                sself.audioBufferList.mBuffers.mDataByteSize = readSize

                var totalReadFrame: UInt32 = frameCount
                guard readSize != 0 else { return nil }

                if readSize != size {
                    totalReadFrame = readSize / bytesPerFrame
                }
                sself._stateQueue.async(flags: .barrier) { sself._progress += Float(totalReadFrame) }
                return withUnsafePointer(to: &sself.audioBufferList, { $0 })
            }

            // Move connect here to avoid using microphone
            if _isConnected == false {
                _isConnected = true
                _engine.connect(_engine.inputNode, to: _eq, format: nil)
                _engine.connect(_eq, to: _engine.mainMixerNode, format: nil)
            }

            _engine.prepare()
            try _engine.start()
        } catch {
            eventPipeline.call(Player.Event.unknown(error))
        }
    }
}

@available(iOS 11.0, *)
private func renderCallback(userInfo: UnsafeMutableRawPointer, ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, inTimeStamp _: UnsafePointer<AudioTimeStamp>, inBusNumber _: UInt32, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let sself = userInfo.to(object: APlayer.self)
    var status = noErr
    _ = sself._renderBlock?(inNumberFrames, ioData!, &status)
    return noErr
}
