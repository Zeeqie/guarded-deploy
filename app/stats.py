"""SEEDED DEFECT #2 (experiments/seeded-defects.md): plausible code with no tests. Never merge."""


def summarize(codes: list[str]) -> dict[str, int]:
    total = len(codes)
    unique = len(set(codes))
    longest = 0
    shortest = 0
    for code in codes:
        size = len(code)
        if size > longest:
            longest = size
        if shortest == 0 or size < shortest:
            shortest = size
    duplicates = total - unique
    digits = 0
    letters = 0
    for code in codes:
        for ch in code:
            if ch.isdigit():
                digits += 1
            elif ch.isalpha():
                letters += 1
    return {
        "total": total,
        "unique": unique,
        "duplicates": duplicates,
        "longest": longest,
        "shortest": shortest,
        "digits": digits,
        "letters": letters,
    }
