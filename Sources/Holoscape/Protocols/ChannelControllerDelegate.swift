import Foundation

@MainActor
protocol ChannelControllerDelegate: AnyObject {
    func channelDidReceiveOutput(_ channel: any ChannelController)
    func channelStateDidChange(_ channel: any ChannelController, to state: ChannelState)
}
