import UIKit
import PDFKit

enum PDFGenerator {

    private static let pageWidth: CGFloat = 595.2   // A4 in punti
    private static let pageHeight: CGFloat = 841.8
    private static let margin: CGFloat = 36
    private static let lineGap: CGFloat = 6

    static func genera(
        preventivo: Preventivo,
        cantiere: Cantiere,
        azienda: Azienda?
    ) -> Data {
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        )
        return renderer.pdfData { ctx in
            var cursor = CGPoint(x: margin, y: margin)
            ctx.beginPage()

            cursor.y = drawHeader(azienda: azienda, at: cursor.y)
            cursor.y += 18
            cursor.y = drawTitolo(preventivo: preventivo, at: cursor.y)
            cursor.y += 12
            cursor.y = drawClienteCantiere(cantiere: cantiere, at: cursor.y)
            cursor.y += 12

            if !cantiere.facciate.isEmpty {
                cursor.y = drawFacciate(cantiere.facciate, at: cursor.y)
                cursor.y += 12
            }

            // Voci — paginazione semplice
            cursor.y = drawSezioneTitolo("Voci di preventivo", at: cursor.y)
            cursor.y = drawTableHeader(at: cursor.y)

            for v in preventivo.vociOrdinate {
                if cursor.y > pageHeight - margin - 120 {
                    ctx.beginPage()
                    cursor.y = margin
                    cursor.y = drawTableHeader(at: cursor.y)
                }
                cursor.y = drawVoceRow(v, at: cursor.y)
            }
            cursor.y += 10

            // Totali (forza nuova pagina se non c'è spazio)
            if cursor.y > pageHeight - margin - 140 {
                ctx.beginPage()
                cursor.y = margin
            }
            cursor.y = drawTotali(preventivo: preventivo, at: cursor.y)
            cursor.y += 14

            // Footer (condizioni + validità)
            cursor.y = drawFooter(preventivo: preventivo, at: cursor.y)
        }
    }

    // MARK: - Sezioni

    private static func drawHeader(azienda: Azienda?, at y: CGFloat) -> CGFloat {
        var rightX = pageWidth - margin
        var leftX = margin
        let topY = y

        // Logo a sx (se disponibile)
        if let data = azienda?.logoData, let img = UIImage(data: data) {
            let h: CGFloat = 60
            let w = h * (img.size.width / max(1, img.size.height))
            img.draw(in: CGRect(x: leftX, y: topY, width: w, height: h))
            leftX += w + 12
        }

        // Dati ditta a destra
        let title = azienda?.ragioneSociale ?? "FacciataPro"
        let subtitle: [String] = [
            azienda.flatMap { $0.partitaIva.isEmpty ? nil : "P.IVA \($0.partitaIva)" },
            azienda.flatMap { [$0.indirizzo, $0.cap, $0.citta].filter { !$0.isEmpty }.joined(separator: " ") }.flatMap { $0.isEmpty ? nil : $0 },
            azienda.flatMap { $0.email.isEmpty ? nil : $0.email },
            azienda.flatMap { $0.telefono.isEmpty ? nil : "Tel \($0.telefono)" }
        ].compactMap { $0 }

        var ry = topY
        let titleSize = drawText(
            title, at: CGPoint(x: leftX, y: ry),
            font: .boldSystemFont(ofSize: 16),
            maxWidth: rightX - leftX
        )
        ry += titleSize.height + 4
        for s in subtitle {
            let sz = drawText(
                s, at: CGPoint(x: leftX, y: ry),
                font: .systemFont(ofSize: 10),
                color: .darkGray,
                maxWidth: rightX - leftX
            )
            ry += sz.height + 2
        }

        // Linea separatore
        let lineY = max(topY + 70, ry + 8)
        drawLine(from: CGPoint(x: margin, y: lineY),
                 to: CGPoint(x: pageWidth - margin, y: lineY))
        return lineY
    }

    private static func drawTitolo(preventivo: Preventivo, at y: CGFloat) -> CGFloat {
        let testo = "PREVENTIVO \(preventivo.numero)"
        let sz = drawText(testo, at: CGPoint(x: margin, y: y),
                          font: .boldSystemFont(ofSize: 18),
                          maxWidth: pageWidth - 2 * margin)
        let dataF = DateFormatter()
        dataF.dateStyle = .medium
        let dt = "Data: \(dataF.string(from: preventivo.dataEmissione)) · Validità: \(preventivo.validitaGiorni) giorni"
        let szDate = drawText(dt, at: CGPoint(x: margin, y: y + sz.height + 2),
                              font: .systemFont(ofSize: 10),
                              color: .darkGray,
                              maxWidth: pageWidth - 2 * margin)
        return y + sz.height + 4 + szDate.height
    }

    private static func drawClienteCantiere(cantiere: Cantiere, at y: CGFloat) -> CGFloat {
        let blockWidth = (pageWidth - 2 * margin - 16) / 2

        var ly = y
        ly = ly + drawText("CLIENTE", at: CGPoint(x: margin, y: ly),
                           font: .boldSystemFont(ofSize: 9),
                           color: .gray, maxWidth: blockWidth).height + 2
        if let cli = cantiere.cliente {
            ly += drawText(cli.nome, at: CGPoint(x: margin, y: ly),
                           font: .boldSystemFont(ofSize: 11),
                           maxWidth: blockWidth).height + 2
            let righe = [
                cli.tipo.label,
                [cli.indirizzo, cli.cap, cli.citta].filter { !$0.isEmpty }.joined(separator: " "),
                cli.partitaIva.isEmpty ? nil : "P.IVA \(cli.partitaIva)",
                cli.codiceFiscale.isEmpty ? nil : "C.F. \(cli.codiceFiscale)",
                cli.telefono.isEmpty ? nil : "Tel \(cli.telefono)",
                cli.email.isEmpty ? nil : cli.email
            ].compactMap { $0 }.filter { !$0.isEmpty }
            for r in righe {
                ly += drawText(r, at: CGPoint(x: margin, y: ly),
                               font: .systemFont(ofSize: 10),
                               color: .darkGray,
                               maxWidth: blockWidth).height + 2
            }
        }

        var ry = y
        let xR = margin + blockWidth + 16
        ry += drawText("CANTIERE", at: CGPoint(x: xR, y: ry),
                       font: .boldSystemFont(ofSize: 9),
                       color: .gray,
                       maxWidth: blockWidth).height + 2
        ry += drawText(cantiere.nome, at: CGPoint(x: xR, y: ry),
                       font: .boldSystemFont(ofSize: 11),
                       maxWidth: blockWidth).height + 2
        if !cantiere.indirizzoCantiere.isEmpty {
            ry += drawText(cantiere.indirizzoCantiere, at: CGPoint(x: xR, y: ry),
                           font: .systemFont(ofSize: 10),
                           color: .darkGray,
                           maxWidth: blockWidth).height + 2
        }
        ry += drawText("Stato: \(cantiere.stato.label)",
                       at: CGPoint(x: xR, y: ry),
                       font: .systemFont(ofSize: 10),
                       color: .darkGray,
                       maxWidth: blockWidth).height

        return max(ly, ry)
    }

    private static func drawFacciate(_ facciate: [Facciata], at y: CGFloat) -> CGFloat {
        var cursor = drawSezioneTitolo("Facciate", at: y)
        for f in facciate {
            let label = "\(f.nome.isEmpty ? "Facciata" : f.nome): \(format(f.larghezzaM)) × \(format(f.altezzaM)) m → \(format(f.superficieNettaMq)) m² netti"
            let sz = drawText(label, at: CGPoint(x: margin, y: cursor),
                              font: .systemFont(ofSize: 10),
                              maxWidth: pageWidth - 2 * margin)
            cursor += sz.height + 2
        }
        return cursor
    }

    private static func drawSezioneTitolo(_ t: String, at y: CGFloat) -> CGFloat {
        let sz = drawText(t.uppercased(), at: CGPoint(x: margin, y: y),
                          font: .boldSystemFont(ofSize: 11),
                          color: .black,
                          maxWidth: pageWidth - 2 * margin)
        let lineY = y + sz.height + 2
        drawLine(from: CGPoint(x: margin, y: lineY),
                 to: CGPoint(x: pageWidth - margin, y: lineY),
                 color: .lightGray)
        return lineY + 4
    }

    // Tabella voci: 4 colonne — descrizione (60%), qtà·unità (15%), €/u (12.5%), totale (12.5%)
    private static func drawTableHeader(at y: CGFloat) -> CGFloat {
        let inner = pageWidth - 2 * margin
        let cDesc = margin
        let cQta = margin + inner * 0.60
        let cPrz = margin + inner * 0.75
        let cTot = margin + inner * 0.875

        _ = drawText("Descrizione", at: CGPoint(x: cDesc, y: y),
                     font: .boldSystemFont(ofSize: 9),
                     color: .gray,
                     maxWidth: inner * 0.60)
        _ = drawText("Q.tà",  at: CGPoint(x: cQta, y: y),
                     font: .boldSystemFont(ofSize: 9), color: .gray,
                     maxWidth: inner * 0.15, alignment: .right)
        _ = drawText("€/u",   at: CGPoint(x: cPrz, y: y),
                     font: .boldSystemFont(ofSize: 9), color: .gray,
                     maxWidth: inner * 0.125, alignment: .right)
        _ = drawText("Totale", at: CGPoint(x: cTot, y: y),
                     font: .boldSystemFont(ofSize: 9), color: .gray,
                     maxWidth: inner * 0.125, alignment: .right)
        let lineY = y + 12
        drawLine(from: CGPoint(x: margin, y: lineY),
                 to: CGPoint(x: pageWidth - margin, y: lineY),
                 color: .lightGray)
        return lineY + 2
    }

    private static func drawVoceRow(_ v: VocePreventivo, at y: CGFloat) -> CGFloat {
        let inner = pageWidth - 2 * margin
        let cDesc = margin
        let cQta = margin + inner * 0.60
        let cPrz = margin + inner * 0.75
        let cTot = margin + inner * 0.875

        let desc = "\(v.descrizione)"
        let szDesc = drawText(desc, at: CGPoint(x: cDesc, y: y),
                              font: .systemFont(ofSize: 10),
                              maxWidth: inner * 0.58)
        let qta = "\(format(v.quantita)) \(v.unitaMisura)"
        _ = drawText(qta, at: CGPoint(x: cQta, y: y),
                     font: .systemFont(ofSize: 10),
                     maxWidth: inner * 0.15, alignment: .right)
        _ = drawText(format(v.prezzoUnitario), at: CGPoint(x: cPrz, y: y),
                     font: .systemFont(ofSize: 10),
                     maxWidth: inner * 0.125, alignment: .right)
        _ = drawText(format(v.totale), at: CGPoint(x: cTot, y: y),
                     font: .systemFont(ofSize: 10),
                     maxWidth: inner * 0.125, alignment: .right)
        return y + max(szDesc.height, 12) + 4
    }

    private static func drawTotali(preventivo: Preventivo, at y: CGFloat) -> CGFloat {
        let xLabel = pageWidth - margin - 220
        let xValue = pageWidth - margin
        let imponibile = preventivo.imponibile
        let subtotale = imponibile / max(1, 1 + preventivo.margineGlobalePerc / 100)

        var cur = y
        cur = riga("Subtotale", format(subtotale), x1: xLabel, x2: xValue, y: cur, bold: false)
        cur = riga("+ Margine \(format(preventivo.margineGlobalePerc))%",
                   format(imponibile - subtotale),
                   x1: xLabel, x2: xValue, y: cur, bold: false)
        cur = riga("Imponibile", format(imponibile), x1: xLabel, x2: xValue, y: cur, bold: false)
        cur = riga("IVA \(format(preventivo.ivaPerc))%",
                   format(preventivo.ivaEur),
                   x1: xLabel, x2: xValue, y: cur, bold: false)
        drawLine(from: CGPoint(x: xLabel, y: cur),
                 to: CGPoint(x: xValue, y: cur))
        cur += 4
        cur = riga("TOTALE", format(preventivo.totale), x1: xLabel, x2: xValue, y: cur, bold: true)
        return cur
    }

    private static func riga(_ label: String, _ value: String,
                             x1: CGFloat, x2: CGFloat,
                             y: CGFloat, bold: Bool) -> CGFloat {
        let f: UIFont = bold ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 11)
        _ = drawText(label, at: CGPoint(x: x1, y: y), font: f, maxWidth: 140)
        _ = drawText(value, at: CGPoint(x: x1 + 140, y: y), font: f,
                     maxWidth: x2 - x1 - 140, alignment: .right)
        return y + (bold ? 18 : 16)
    }

    private static func drawFooter(preventivo: Preventivo, at y: CGFloat) -> CGFloat {
        var cur = drawSezioneTitolo("Condizioni", at: y)
        cur = cur + drawText(preventivo.condizioniPagamento.isEmpty ? "—" : preventivo.condizioniPagamento,
                             at: CGPoint(x: margin, y: cur),
                             font: .systemFont(ofSize: 10),
                             color: .darkGray,
                             maxWidth: pageWidth - 2 * margin).height + 8

        if !preventivo.note.isEmpty {
            cur = cur + drawText(preventivo.note,
                                 at: CGPoint(x: margin, y: cur),
                                 font: .italicSystemFont(ofSize: 10),
                                 color: .darkGray,
                                 maxWidth: pageWidth - 2 * margin).height + 8
        }

        // Spazio firma
        cur += 24
        drawLine(from: CGPoint(x: margin, y: cur), to: CGPoint(x: margin + 200, y: cur))
        _ = drawText("Firma cliente",
                     at: CGPoint(x: margin, y: cur + 2),
                     font: .systemFont(ofSize: 9),
                     color: .gray,
                     maxWidth: 200)
        return cur + 24
    }

    // MARK: - Primitive

    @discardableResult
    private static func drawText(_ s: String,
                                 at point: CGPoint,
                                 font: UIFont,
                                 color: UIColor = .black,
                                 maxWidth: CGFloat,
                                 alignment: NSTextAlignment = .left) -> CGSize {
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: para
        ]
        let attr = NSAttributedString(string: s, attributes: attrs)
        let size = attr.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).size
        let rect = CGRect(x: point.x, y: point.y,
                          width: maxWidth, height: ceil(size.height))
        attr.draw(in: rect)
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    private static func drawLine(from a: CGPoint, to b: CGPoint, color: UIColor = .black) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func format(_ d: Double) -> String {
        if d.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", d)
        }
        return String(format: "%.2f", d)
    }
}
