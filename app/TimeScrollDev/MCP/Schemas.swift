import Foundation
enum Schemas {
    static let searchInput: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "The search query. Leave query empty to return the latest snapshots."],
            "max_results": ["type":"integer","minimum":1,"maximum":100,"default":20],
            "include_images": ["type":"boolean","default":false, "description":"Include snapshot images (JPEG) for the first 10 results. Images are large; request them only when the text is not enough."],
            "date_range": [
                "type":"object",
                "properties":[ "from":["type":"string","format":"date-time"],
                               "to":  ["type":"string","format":"date-time"] ],
                "additionalProperties": false
            ],
            "text_only": ["type":"boolean","default":false,
                          "description":"false = Use AI search mode. true = Only search within raw text in snapshots. AI search is more powerful."],
            "apps": ["type":"array","items":["type":"string"],
                     "description":"List of app bundle IDs to include. Leave empty to include all apps. Example: [\"com.apple.Safari\",\"com.microsoft.VSCode\"]"]
            ,
            "image_max_pixel": ["type":"integer","minimum":256,"maximum":2048,"default":1024,
                                 "description":"Max pixel length (longest edge) for returned images. Raise only when small text in the image must be legible."]
        ],
        "required": []
    ]

    static let searchOutput: [String: Any] = [
        "type":"object",
        "properties":[
            "results":[
                "type":"array",
                "items":[
                    "type":"object",
                    "properties":[
                        "time":["type":"string","format":"date-time"],
                        "app":["type":"string"],
                        "ocr_text":["type":"string"]
                    ],
                    "required":["time","ocr_text"]
                ]
            ]
        ],
        "required":["results"]
    ]
}
