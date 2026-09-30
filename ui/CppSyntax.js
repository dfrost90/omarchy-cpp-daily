// Small display-only C++ lexer. Escape every token before adding rich-text markup.
function escapeHtml(text) {
    return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
function highlight(source, palette) {
    var tokens = /\/\/[^\n]*|\/\*[\s\S]*?\*\/|"(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*'|\b(?:0[xX][\da-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)[uUlLfF]*\b|\b[A-Za-z_]\w*\b|[^]/g;
    var keywords = /^(?:alignas|auto|bool|break|case|char|class|const|constexpr|continue|default|delete|do|double|else|enum|explicit|false|float|for|if|inline|int|long|namespace|new|nullptr|private|protected|public|return|short|signed|sizeof|static|static_assert|static_cast|struct|switch|template|this|throw|true|typename|unsigned|using|virtual|void|volatile|while)$/;
    return '<pre style="margin:0; white-space:pre-wrap">' + source.replace(tokens, function(token) {
        var color = token.slice(0, 2) === '//' || token.slice(0, 2) === '/*' ? palette.comment
            : token[0] === '"' || token[0] === "'" ? palette.string
            : /^\d/.test(token) ? palette.number
            : keywords.test(token) ? palette.keyword : null;
        var escaped = escapeHtml(token);
        return color ? '<span style="color:' + color + '">' + escaped + '</span>' : escaped;
    }) + '</pre>';
}
