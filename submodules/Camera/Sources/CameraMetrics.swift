import Foundation
import AVFoundation
import DeviceModel

public extension Camera {
    enum Metrics {
        case singleCamera
        case iPhone14
        case iPhone14Plus
        case iPhone14Pro
        case iPhone14ProMax
        case iPhone15
        case iPhone15Plus
        case iPhone15Pro
        case iPhone15ProMax
        case iPhone17
        case iPhone17Pro
        case iPhoneAir
        case unknown
        
        public init(model: DeviceModel) {
            switch model {
            case .iPodTouch1, .iPodTouch2, .iPodTouch3, .iPodTouch4, .iPodTouch5, .iPodTouch6, .iPodTouch7,
                 .iPhone, .iPhone3G, .iPhone3GS, .iPhone4, .iPhone4S, .iPhone5, .iPhone5C, .iPhone5S,
                 .iPhone6, .iPhone6Plus, .iPhone6S, .iPhone6SPlus, .iPhoneSE, .iPhone7, .iPhone8,
                 .iPhoneXR, .iPhoneSE2ndGen, .iPhoneSE3rdGen:
                self = .singleCamera
            case .iPhone7Plus, .iPhone8Plus, .iPhoneX, .iPhoneXS, .iPhoneXSMax, .iPhone16e, .iPhoneAir:
                self = .iPhoneAir
            case .iPhone11, .iPhone11Pro, .iPhone11ProMax,
                 .iPhone12, .iPhone12Mini, .iPhone12Pro, .iPhone12ProMax,
                 .iPhone13, .iPhone13Mini,
                 .iPhone14, .iPhone16, .iPhone16Plus:
                self = .iPhone14
            case .iPhone14Plus:
                self = .iPhone14Plus
            case .iPhone13Pro, .iPhone13ProMax, .iPhone14Pro:
                self = .iPhone14Pro
            case .iPhone14ProMax:
                self = .iPhone14ProMax
            case .iPhone15:
                self = .iPhone15
            case .iPhone15Plus:
                self = .iPhone15Plus
            case .iPhone15Pro, .iPhone16Pro:
                self = .iPhone15Pro
            case .iPhone15ProMax, .iPhone16ProMax:
                self = .iPhone15ProMax
            case .iPhone17:
                self = .iPhone17
            case .iPhone17Pro, .iPhone17ProMax, .iPhone18Pro, .iPhone18ProMax:
                self = .iPhone17Pro
            case .unknown:
                self = .unknown
            default:
                self = .unknown
            }
        }
        
        public var zoomLevels: [Float] {
            switch self {
            case .singleCamera:
                return [1.0]
            case .iPhone14, .iPhone14Plus, .iPhone15, .iPhone15Plus, .iPhone17:
                return [0.5, 1.0, 2.0]
            case .iPhone14Pro, .iPhone14ProMax, .iPhone15Pro:
                return [0.5, 1.0, 2.0, 3.0]
            case .iPhone15ProMax:
                return [0.5, 1.0, 2.0, 5.0]
            case .iPhone17Pro:
                return [0.5, 1.0, 2.0, 8.0]
            case .iPhoneAir:
                return [1.0, 2.0]
            case .unknown:
                return Camera.backCameraSupportsUltraWide() ? [0.5, 1.0, 2.0] : [1.0, 2.0]
            }
        }
    }
}
