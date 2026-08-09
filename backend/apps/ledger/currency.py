from __future__ import annotations

from rest_framework import serializers

# Active ISO 4217 fiat/fund codes accepted by the first release. Most currencies use
# two minor-unit digits; the explicit maps capture ISO exceptions. A stored exponent
# snapshot makes historical records deterministic if the standard changes later.
_CURRENCY_CODES = frozenset(
    """
    AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BGN BHD BIF BMD BND
    BOB BOV BRL BSD BTN BWP BYN BZD CAD CDF CHE CHF CHW CLF CLP CNY COP COU
    CRC CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP GBP GEL GHS GIP
    GMD GNF GTQ GYD HKD HNL HTG HUF IDR ILS INR IQD IRR ISK JMD JOD JPY KES
    KGS KHR KMF KPW KRW KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA MKD
    MMK MNT MOP MRU MUR MVR MWK MXN MXV MYR MZN NAD NGN NIO NOK NPR NZD OMR
    PAB PEN PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR SBD SCR SDG SEK SGD
    SHP SLE SOS SRD SSP STN SVC SYP SZL THB TJS TMT TND TOP TRY TTD TWD TZS
    UAH UGX USD USN UYI UYU UYW UZS VED VES VND VUV WST XAF XCD XOF XPF YER
    ZAR ZMW ZWG
    """.split()  # noqa: SIM905 - grouped table is easier to audit than a 170-item literal
)
_ZERO_EXPONENT = frozenset(
    {
        "BIF",
        "CLP",
        "DJF",
        "GNF",
        "ISK",
        "JPY",
        "KMF",
        "KRW",
        "PYG",
        "RWF",
        "UGX",
        "UYI",
        "VND",
        "VUV",
        "XAF",
        "XOF",
        "XPF",
    }
)
_THREE_EXPONENT = frozenset({"BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"})
_FOUR_EXPONENT = frozenset({"CLF", "UYW"})


def normalize_currency(value: str) -> str:
    code = value.strip().upper()
    if code not in _CURRENCY_CODES:
        raise serializers.ValidationError("Use a supported ISO 4217 currency code.")
    return code


def currency_exponent(code: str) -> int:
    normalized = normalize_currency(code)
    if normalized in _ZERO_EXPONENT:
        return 0
    if normalized in _THREE_EXPONENT:
        return 3
    if normalized in _FOUR_EXPONENT:
        return 4
    return 2
