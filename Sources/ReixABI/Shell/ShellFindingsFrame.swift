//
//  ShellFindingsFrame.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

public enum ShellFindingsFrame {

    public static let recordCount = 20

    public static func validates(_ frame: ShellFrame) -> Bool {

        guard frame.envelope.schema == .fileSystemFindings,
              frame.recordCount == recordCount
        else { return false }

        var values = InlineArray<20, UInt32>(repeating: 0)
        for index in 0..<recordCount {

            guard let scalar = frame.scalar(at: index),
                  scalar.kind == (index == 0 ? .status : .scalar),
                  scalar.field == expectedField(at: index)
            else { return false }

            values[index] = scalar.value
        }

        guard values[1] <= 1, values[2] <= 1, values[3] <= 1, values[12] <= 1,
              values[17] <= 1, values[18] <= 1, values[19] <= 1
        else { return false }

        if values[19] == 1 {
            return values[0] == FSStatus.ok.rawValue && frame.envelope.flags == [.end]
                && values[1]  == 1 && values[2]  == 1 && values[3]  == 1
                && values[5]  == 0 && values[6]  == 0 && values[7]  == 0
                && values[8]  == 0 && values[9]  == 0 && values[10] == 0
                && values[11] == 0 && values[12] == 0 && values[13] == 0
                && values[14] == 0 && values[15] == 0 && values[18] == 0
        }

        return values[0] == FSStatus.deviceFailed.rawValue &&
               frame.envelope.flags == [.end, .error]
    }

    private static func expectedField(at index: Int) -> ShellField? {

        switch index {
            case 0: .status
            case 1: .complete
            case 2: .scrubDepth

            case 3: .quotasChecked
            case 4: .reclaimableBlocks
            case 5: .ownedButFree

            case 6: .claimedTwice
            case 7: .impossible
            case 8: .strayNames

            case 9: .duplicateNames
            case 10: .duplicateTargets
            case 11: .brokenEntries

            case 12: .nameScrubBudgetExhausted
            case 13: .wrongQuota
            case 14: .strayCharges

            case 15: .selfParented
            case 16: .roomsMended
            case 17: .mapMended

            case 18: .tooManyContainers
            case 19: .safeToServe
            default: nil
        }
    }
}
