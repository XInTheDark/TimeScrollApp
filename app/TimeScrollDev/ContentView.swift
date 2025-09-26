//
//  ContentView.swift
//  TimeScrollDev
//
//  Created by Muzhen J on 9/18/25.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TimelineUnifiedView()
            .padding(.bottom)
            .frame(minWidth: 1000, minHeight: 700)
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}
#endif
