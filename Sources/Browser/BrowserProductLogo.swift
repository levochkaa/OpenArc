// BrowserProductLogo.swift

import AppKit

/// OpenArc's icon for the engine's own pages (History, Settings, Downloads),
/// whose toolbars otherwise show the engine's logo.
@MainActor @objc final class BrowserProductLogo: NSObject {
    /// The app icon as a 64 px PNG data URL, made once.
    @objc static let dataURL: String? = {
        let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        guard let icon, let image = BrowserImageThumbnailer.resizedImage(icon, fitting: 64),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }()

    /// Replaces the logo in an internal page's toolbar, inside its shadow roots,
    /// once the page has drawn it.
    @objc static func script(dataURL: String) -> String {
        """
        (function(){var logo=\(String(reflecting: dataURL));
        function find(root,depth){if(!root||depth>6)return null;var img=root.querySelector('img#product-logo');
        if(img)return img;var all=root.querySelectorAll('*');for(var i=0;i<all.length;i++){
        if(all[i].shadowRoot){var f=find(all[i].shadowRoot,depth+1);if(f)return f;}}return null;}
        var tries=0;var timer=setInterval(function(){var img=find(document,0);
        if(img){var p=img.parentNode;if(p&&p.tagName==='PICTURE'){p.querySelectorAll('source').forEach(function(s){s.remove();});}
        img.removeAttribute('srcset');img.src=logo;clearInterval(timer);}else if(++tries>100){clearInterval(timer);}},50);})();
        """
    }
}
