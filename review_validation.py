"""Focused review contract and conservative deterministic checks. No network or persistence."""
import re
import unicodedata
from collections import Counter

# The reviewer replies with exactly this when the draft needs no correction.
# It is deliberately not a word that could be a real translation.
UNCHANGED = "<<UNCHANGED>>"

# English-to-Japanese brewing/business regressions: (source pattern, required
# target pattern, source term, approved target term).
JAPANESE_TERMS = [
    (r"\bkegging\b", r"樽詰め", "Kegging", "樽詰め"),
    (r"\blauter\b", r"ろ過|濾過|ロイター|ロイタリング|ラウター|Lauter", "Lauter", "麦汁ろ過"),
    (r"\bexcise tax report\b", r"(?:酒税|物品税).*(?:レポート|報告|申告)", "Excise Tax Report", "酒税レポート"),
    (r"\bseveral meetings\b", r"(?:複数|数回|何度|何回|いくつか|数件).*(?:会議|打ち合わせ|打合せ|ミーティング)", "Several meetings", "複数の会議"),
    (r"\bput aside for staff\b", r"(?:スタッフ|従業員|職員).*(?:取り置|取って|確保|保留|別に|取[り]?[分置])", "Put aside for staff", "スタッフ用に取り置き"),
    (r"\brecipe cost information\b", r"レシピ.*(?:原価|コスト|費用).*情報", "Recipe cost information", "レシピ原価情報"),
]
DILUTION = r"calculated dilution amount\s+vs\s+actual dilution amount"
# (source pattern, source term, incorrect forms, correct replacement)
JAPANESE_FORBIDDEN = [(r"\bAyano-san\b", "Ayano-san", ("綾野様", "青山様"), "Ayano-san"),
                      (r"\bkegging\b", "Kegging", ("ケージング",), "樽詰め"),
                      (r"\blauter\b", "Lauter", ("ロイヤー",), "麦汁ろ過"),
                      (r"\bexcise tax report\b", "Excise Tax Report", ("減価税",), "酒税")]
# Spelled-out English numbers a translation may legitimately write as digits.
NUMBER_WORDS = {word: str(value) for value, word in enumerate(
    ("zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"))}


def required_terminology(source, source_language, target_language):
    """Approved source-to-target terms for the selected pair, as positive data."""
    if source_language != "en" or target_language != "ja": return {}
    result = {term: approved for pattern, _, term, approved in JAPANESE_TERMS if re.search(pattern, source, re.I)}
    if re.search(DILUTION, source, re.I):
        result["Calculated Dilution Amount vs Actual Dilution Amount"] = "計算上の希釈量と実際の希釈量の比較"
    return result


def protected_literals(source):
    # Explicit identifiers, Roman names with honorifics, CamelCase software names.
    # Do not guess kanji for a Roman personal name. Other names need semantic review.
    patterns = [r"\b[A-Z][a-z]+(?:-[A-Z][a-z]+)*-(?:san|sama|kun|chan|sensei)\b",
                r"\be-Tax\b", r"\b[A-Z][a-z]+(?:[A-Z][a-zA-Z0-9]+)+\b",
                r"`([^`\n]+)`", r"https?://[^\s<>]+", r"\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b"]
    return sorted({value for pattern in patterns for value in re.findall(pattern, source)})


def normalized_digits(text):
    text = unicodedata.normalize("NFKC", text).replace("−", "-").replace("٫", ".").replace("٬", ",")
    return "".join(str(unicodedata.decimal(char)) if char.isdecimal() else char for char in text)


def numbers(text):
    return Counter(re.findall(r"(?<![0-9A-Za-z_])[-+]?\d+(?:[.,]\d+)*(?:%|％)?", normalized_digits(text)))


UNIT_ALIASES = {
    "L": ("L", "l", "litre", "litres", "liter", "liters", "litro", "litros", "Liter", "リットル", "公升"),
    "mL": ("mL", "ml", "millilitre", "millilitres", "milliliter", "milliliters", "mililitro", "mililitros", "ミリリットル", "毫升"),
    "kg": ("kg", "kilogram", "kilograms", "kilogramme", "kilogrammes", "kilogramo", "kilogramos", "キログラム", "千克"),
    "mg": ("mg", "milligram", "milligrams", "miligramo", "miligramos", "ミリグラム"),
    **{unit: (unit,) for unit in ("kWh", "°C", "°F", "km", "cm", "mm")}}
CANONICAL_UNITS = {alias: unit for unit, values in UNIT_ALIASES.items() for alias in values}
QUANTITY = re.compile(r"(?<![0-9A-Za-z_])([-+]?\d+(?:[.,]\d+)*)\s*("
                      + "|".join(re.escape(alias) for alias in sorted(CANONICAL_UNITS, key=len, reverse=True))
                      + r")(?![A-Za-z])")


def quantities(text):
    """Quantity/unit pairs, so swapping 12 L and 5 kg is also detected."""
    return Counter((number.replace(",", "."), CANONICAL_UNITS[unit]) for number, unit in QUANTITY.findall(normalized_digits(text)))


def translation_findings(source, output, source_language, target_language):
    """Deterministic (code, explanation) findings for a candidate translation."""
    findings = []
    for literal in protected_literals(source):
        if output.count(literal) < source.count(literal):
            findings.append(("protected_literal", "%r is missing or written differently. Wherever the draft renders it "
                             "another way (for example in kanji or katakana), write exactly %s instead." % (literal, literal)))
    # Unicode digits are normalized and decimal comma/point localization is permitted.
    def canonical(text):
        result = Counter()
        for value, count in numbers(text).items(): result[value.replace(",", ".")] += count
        return result
    expected, actual = canonical(source), canonical(output)
    if source_language == "en":
        # A digit in the translation may stand for a number word in the English source.
        words = Counter(NUMBER_WORDS[word.lower()] for word in re.findall(r"\b[A-Za-z]+\b", source) if word.lower() in NUMBER_WORDS)
        extra = actual - expected
        actual = actual - Counter({value: min(count, words[value]) for value, count in extra.items()})
    if expected != actual:
        findings.append(("numbers", "The numbers do not match the original."))
    if len(re.findall(r"^#{1,6}\s+", source, re.M)) != len(re.findall(r"^#{1,6}\s+", output, re.M)):
        findings.append(("headings", "The Markdown headings do not match the original."))
    if quantities(source) != quantities(output):
        findings.append(("units", "Quantities and their units do not match the original."))
    if source_language == "en" and target_language == "ja":
        for pattern, expected, term, approved in JAPANESE_TERMS:
            if re.search(pattern, source, re.I) and not re.search(expected, output, re.I | re.S):
                findings.append(("terminology_or_omission", "%r is missing or mistranslated. Translate it as %s." % (term, approved)))
        for pattern, term, wrong_forms, replacement in JAPANESE_FORBIDDEN:
            for wrong in wrong_forms:
                if re.search(pattern, source, re.I) and wrong in output and wrong not in source:
                    findings.append(("known_mistranslation", "Replace %s with %s (%s is an incorrect rendering of %r)." % (wrong, replacement, wrong, term)))
        if re.search(DILUTION, source, re.I) and not re.search(r"evaporat", source, re.I) and "蒸発" in output:
            findings.append(("invented_evaporation", "Remove 蒸発 (evaporation); it is not in the original."))
    return findings


def preservation_errors(source, output, source_language, target_language):
    return sorted({code for code, _ in translation_findings(source, output, source_language, target_language)})


COMMENTARY = re.compile(r"^\s*(?:here\s+is|here's|corrected\s+translation|translation|draft|original|review|note)\b[^\n]{0,40}:",
                        re.I)
DELIMITER = re.compile(r"</?(?:original|draft|custom_instructions)>", re.I)


def interpret_review(raw, source, draft, source_language, target_language):
    """Return (final_translation, changed). Raise ValueError for any review that
    is empty, ambiguous, apparently incomplete, or fails deterministic checks."""
    if not isinstance(raw, str): raise ValueError("invalid review")
    text = raw.strip()
    fenced = re.fullmatch(r"```[^\n`]*\n(.*?)\n?```", text, re.S)
    if fenced: text = fenced.group(1).strip()
    if not text: raise ValueError("empty review")
    if text == UNCHANGED:
        output, changed = draft, False
    else:
        if "<<UNCHANGED" in text or "UNCHANGED>>" in text: raise ValueError("ambiguous review signal")
        if (COMMENTARY.match(text) and not COMMENTARY.match(draft)) or (DELIMITER.search(text) and not DELIMITER.search(source + draft)):
            raise ValueError("review commentary")
        # A model that stops early can return a fragment. A focused review only
        # adds or removes small amounts, so a large shrinkage is not accepted.
        if len(draft.strip()) >= 200 and len(text) < 0.6 * len(draft.strip()):
            raise ValueError("incomplete review")
        output = text
        # A whitespace-only difference cannot improve fidelity; keep the draft's layout.
        if output.split() == draft.split(): output = draft
        changed = output != draft
    errors = preservation_errors(source, output, source_language, target_language)
    if errors: raise ValueError("preservation checks: " + ", ".join(errors))
    return output, changed
