#if DEBUG
import Foundation

/// Public-viewing test inputs, not a bundled channel service or a rights grant.
/// The live app harness uses these instead of the synthetic layout fixtures.
public enum LiveTVPrototypeCatalog {
    public static let channels: [LiveTVPrototypeChannel] = [
        channel(
            id: "DW.de@English", number: 1, name: "DW English", category: "News",
            tagline: "World news and perspectives from Germany.",
            stream: "https://dwamdstream102.akamaized.net/hls/live/2015525/dwstream102/master.m3u8",
            logo: "https://i.imgur.com/8MRNFb9.png"
        ),
        channel(
            id: "NHKWorldJapan.jp@SD", number: 2, name: "NHK WORLD-JAPAN", category: "Culture",
            tagline: "Japan and Asia, news and culture.",
            stream: "https://masterpl.hls.nhkworld.jp/hls/w/live/master.m3u8",
            logo: "https://jiotvimages.cdn.jio.com/dare_images/images/NHK_World_Japan.png"
        ),
        channel(
            id: "TRTWorld.tr@SD", number: 3, name: "TRT World", category: "News",
            tagline: "International news and current affairs.",
            stream: "https://tv-trtworld.medya.trt.com.tr/master.m3u8",
            logo: "https://upload.wikimedia.org/wikipedia/commons/thumb/2/27/TRT_World.svg/960px-TRT_World.svg.png"
        ),
        channel(
            id: "NBCNewsNOW.us@SD", number: 4, name: "NBC News NOW", category: "News",
            tagline: "Breaking news and reporting.",
            stream: "https://d1si3n1st4nkgb.cloudfront.net/10502/88896001/hls/master.m3u8?ads.xumo_channelId=88896001",
            logo: "https://i.imgur.com/JZt2qh5.png"
        ),
        channel(
            id: "ScrippsNews.us@SD", number: 5, name: "Scripps News", category: "News",
            tagline: "News and in-depth reporting.",
            stream: "https://aegis-cloudfront-1.tubi.video/7e1c26b7-7975-4240-9a4f-480eaa8f3ea4/playlist.m3u8",
            logo: "https://i.imgur.com/W0Jvi5o.png"
        ),
        channel(
            id: "RedBullTV.at@US", number: 6, name: "Red Bull TV", category: "Sports",
            tagline: "Adventure and action sports.",
            stream: "https://0b73ace69ebb45eaa249bb87837cb958.mediatailor.us-west-2.amazonaws.com/v1/master/ba62fe743df0fe93366eba3a257d792884136c7f/LINEAR-644-WORBUSENFAST-LG_US/644/lgtv/hls/master/playlist.m3u8",
            logo: "https://images.pluto.tv/channels/5e7cb84a172a0f0007da69e4/colorLogoPNG.png"
        ),
        channel(
            id: "Tastemade.us@US", number: 7, name: "Tastemade", category: "Food",
            tagline: "Food, home and discovery.",
            stream: "https://rakutenaa-tm-intl-aus-rakuten-eu-n1gtg.amagi.tv/playlist/rakutenAA-tm-intl-aus-rakuten-eu/playlist.m3u8",
            logo: "https://i.imgur.com/xP7Ehn8.png",
            logoNeedsDarkBackground: true
        ),
        channel(
            id: "DW.de@Spanish", number: 8, name: "DW Español", category: "News",
            tagline: "World news in Spanish.",
            stream: "https://dwamdstream104.akamaized.net/hls/live/2015530/dwstream104/master.m3u8",
            logo: "https://i.imgur.com/8MRNFb9.png"
        ),
        channel(
            id: "DW.de@Arabic", number: 9, name: "DW Arabic", category: "News",
            tagline: "World news in Arabic.",
            stream: "https://dwamdstream103.akamaized.net/hls/live/2015526/dwstream103/master.m3u8",
            logo: "https://i.imgur.com/8MRNFb9.png"
        )
    ]

    private static func channel(
        id: String, number: Int, name: String, category: String,
        tagline: String, stream: String, logo: String, logoNeedsDarkBackground: Bool = false
    ) -> LiveTVPrototypeChannel {
        guard let streamURL = URL(string: stream), streamURL.scheme == "https",
              let logoURL = URL(string: logo), logoURL.scheme == "https" else {
            preconditionFailure("Invalid public test channel URL")
        }
        return LiveTVPrototypeChannel(
            id: "public-test:\(id)", number: number, name: name, category: category,
            symbol: "tv", accent: (number - 1) % 6, source: .iptv,
            tagline: tagline, logoURL: logoURL, streamURL: streamURL,
            logoNeedsDarkBackground: logoNeedsDarkBackground
        )
    }
}
#endif
