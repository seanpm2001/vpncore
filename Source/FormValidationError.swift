//
//  FormValidationError.swift
//  vpncore - Created on 03/10/2019.
//
//  Copyright (c) 2019 Proton Technologies AG
//
//  This file is part of vpncore.
//
//  vpncore is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  vpncore is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with vpncore.  If not, see <https://www.gnu.org/licenses/>.

import Foundation

/// Errors in form validation
public enum FormValidationError: Error {
    case wrongEmail
    case emptyValue
    case passwordsDontMatch
    case passwordTooShort
}

extension FormValidationError: LocalizedError {
    
    public var errorDescription: String? {
        switch self {
        case .wrongEmail:
            return LocalizedString.errorFieldWrongEmailFormat
        case .emptyValue:
            return LocalizedString.errorFieldRequired
        case .passwordsDontMatch:
            return LocalizedString.errorFieldPasswordDontMatch
        case .passwordTooShort:
            return LocalizedString.lengthPassword
        }
    }
    
    public var identifier: String {
        switch self {
        case .wrongEmail:
            return "wrongEmail"
        case .emptyValue:
            return "emptyValue"
        case .passwordsDontMatch:
            return "passwordsDontMatch"
        case .passwordTooShort:
            return "passwordTooShort"
        }
    }
    
}
