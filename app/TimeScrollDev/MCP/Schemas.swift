import Foundation
enum Schemas {
    static let searchInput: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "The search query. Leave query empty to return the latest snapshots."],
            "max_results": ["type":"integer","minimum":1,"maximum":100,"default":20],
            "include_images": ["type":"boolean","default":true, "description":"Include snapshot images in results."],
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
            "image_max_pixel": ["type":"integer","minimum":1024,"maximum":8192,"default":2048,
                                 "description":"Max pixel length (longest edge) for returned images. Do not change unless you need to get a better quality image."]
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
