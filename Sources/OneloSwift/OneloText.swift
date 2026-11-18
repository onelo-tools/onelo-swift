import Foundation
import os

/// #1074 — the language this SDK's own texts are drawn in: the App's **Page
/// Language** (ADR-0043). The order is the language the App passes
/// (`Onelo(language:)`), else the device language when it is one of the App
/// Languages, else the App's default — the same language as the Hosted Pages.
///
/// The SDK never chooses it. `/api/sdk/config` is asked with the App's
/// language (or the device language) and answers `page_language`, chosen in
/// Python; the SDK adopts that answer, keeps it for the next launch's first
/// paint, and renders. Until a first answer arrives (and with nothing kept from
/// an earlier launch) the texts are English: the language every App starts with.
///
/// One value per process: an `OneloError`'s description has no SDK instance to
/// ask. An app that builds two `Onelo` instances gets the latest answer.
enum OneloPageLanguage {
    /// The languages Onelo translates its own texts into (`SUPPORTED_LANGUAGES`
    /// in `backend/app/lib/app_languages.py`). `pt` is European Portuguese.
    static let supported: [String] = ["en", "pl", "de", "fr", "es", "it", "pt", "nl"]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current = "en"

    /// The Page Language the texts are drawn in now.
    static var current: String { lock.withLock { _current } }

    /// Adopt the Page Language the backend answered. Tags compare by primary
    /// subtag (`pl-PL` → `pl`). Returns the adopted value; `nil` (nothing
    /// changes) when the answer is missing or no language tag.
    @discardableResult
    static func adopt(_ answer: String?) -> String? {
        guard let primary = primarySubtag(answer) else { return nil }
        lock.withLock { _current = primary }
        return primary
    }

    /// The device's preferred languages as an `Accept-Language` value
    /// (`pl-PL, en;q=0.9, …`): the backend's next choice when the language
    /// asked with (the App's, or the device's first) is not one the App offers.
    static func deviceAcceptLanguage(_ preferred: [String] = Locale.preferredLanguages) -> String? {
        let tags = preferred.prefix(6).filter { primarySubtag($0) != nil }
        guard !tags.isEmpty else { return nil }
        return tags.enumerated().map { i, tag in
            i == 0 ? tag : "\(tag);q=\(String(format: "%.1f", max(0.1, 1.0 - Double(i) * 0.1)))"
        }.joined(separator: ", ")
    }

    static func primarySubtag(_ tag: String?) -> String? {
        guard let tag else { return nil }
        let primary = tag.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first
            .map { $0.lowercased() } ?? ""
        guard (2...3).contains(primary.count), primary.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return nil
        }
        return primary
    }
}

/// #1074 — every text this SDK draws itself, in the eight languages Onelo
/// translates into. A developer's own content (app name, plan names, their
/// texts) is never here: it is shown as written. Log lines and messages that
/// address the developer (an invalid key, a missing configuration) stay English.
enum OneloText: String, CaseIterable, Sendable {
    // Chrome
    case close
    case signIn
    case useDifferentMethod
    case signingYouIn
    case sendFeedback
    case manageAccount
    case tryAgain
    case couldNotLoadFeedback
    // Feature badges (`FeatureState.badgeLabel`); the plan name is shown as written.
    // The hosted page's own words: Coming soon / Available in <plan> are
    // `lockComingSoon` / `lockAvailableIn` (frontend/lib/hosted-notice-i18n.ts),
    // Upgrade is the Store's `changePlan` (frontend/lib/store-i18n.ts).
    case badgeNew
    case badgeBeta
    case badgeComingSoon
    case badgeAvailableIn
    case badgeUpgrade
    // Sign-in screen messages
    case couldNotConfirmAccess
    case storeNotConfiguredContactSupport
    case signInIncomplete
    case somethingWentWrong
    case connectionProblem
    case callbackUnexpectedHost
    case callbackMissingCode
    case signInWindowLostConnection
    // OneloAuthViewModel checks
    case enterEmailAndPassword
    case passwordsDoNotMatch
    case passwordTooShort
    case enterEmail
    // OneloError descriptions an App User may be shown
    case errorNotAuthenticated
    case errorInvalidResponse
    case errorNetwork
    case errorCancelled
    case errorTimeout
    case errorStoreNotConfigured
    case errorInAppStoreNotAllowed
    case errorSessionEnded
    case errorUserRevoked
    case errorNoActivePlan
    case errorVerificationRateLimited
    case errorInvalidVerificationToken

    /// This text in the current Page Language; English for a language Onelo
    /// does not translate into (one carried over from an older setting).
    var text: String { text(in: OneloPageLanguage.current) }

    /// This text in `language`, English when Onelo has no translation for it.
    func text(in language: String) -> String {
        let lang = OneloPageLanguage.primarySubtag(language) ?? "en"
        return OneloText.table[lang]?[self] ?? OneloText.table["en"]![self]!
    }

    /// A text carrying a technical detail (`{detail}`), e.g. a network error.
    func text(detail: String) -> String {
        self.text.replacingOccurrences(of: "{detail}", with: detail)
    }

    static let table: [String: [OneloText: String]] = [
        "en": [
            .close: "Close",
            .signIn: "Sign In",
            .useDifferentMethod: "Use a different method",
            .signingYouIn: "Signing you in…",
            .sendFeedback: "Send Feedback",
            .manageAccount: "Manage Account",
            .tryAgain: "Try again",
            .couldNotLoadFeedback: "Couldn't load feedback",
            .badgeNew: "New",
            .badgeBeta: "Beta",
            .badgeComingSoon: "Coming soon",
            .badgeAvailableIn: "Available in {detail}",
            .badgeUpgrade: "Change plan",
            .couldNotConfirmAccess: "Couldn't confirm your access. Please try again.",
            .storeNotConfiguredContactSupport: "The store hasn't been configured yet. Please contact support.",
            .signInIncomplete: "Sign-in did not complete. Please try again.",
            .somethingWentWrong: "Something went wrong. Please try again.",
            .connectionProblem: "Couldn't connect. Check your internet connection and try again.",
            .callbackUnexpectedHost: "Auth callback URL has unexpected host",
            .callbackMissingCode: "Auth callback missing code parameter",
            .signInWindowLostConnection: "The sign-in window lost its connection. Please try again.",
            .enterEmailAndPassword: "Please enter your email and password.",
            .passwordsDoNotMatch: "Passwords do not match.",
            .passwordTooShort: "Password must be at least 8 characters.",
            .enterEmail: "Please enter your email address.",
            .errorNotAuthenticated: "User is not authenticated",
            .errorInvalidResponse: "Invalid response from server",
            .errorNetwork: "Network error: {detail}",
            .errorCancelled: "Sign in was cancelled",
            .errorTimeout: "Timed out: {detail}",
            .errorStoreNotConfigured: "The store hasn't been configured for this app yet.",
            .errorInAppStoreNotAllowed: "Plans can't be purchased inside this app. Buyers purchase on the web and sign in here.",
            .errorSessionEnded: "Your session ended — please sign in again",
            .errorUserRevoked: "This user account has been suspended",
            .errorNoActivePlan: "No active subscription — the plan has expired or was cancelled.",
            .errorVerificationRateLimited: "At most 3 verification emails an hour — try again later",
            .errorInvalidVerificationToken: "This verification link is invalid, already used, replaced by a newer one, or expired",
        ],
        "pl": [
            .close: "Zamknij",
            .signIn: "Zaloguj się",
            .useDifferentMethod: "Użyj innej metody",
            .signingYouIn: "Logowanie…",
            .sendFeedback: "Wyślij opinię",
            .manageAccount: "Zarządzaj kontem",
            .tryAgain: "Spróbuj ponownie",
            .couldNotLoadFeedback: "Nie udało się wczytać formularza opinii",
            .badgeNew: "Nowość",
            .badgeBeta: "Beta",
            .badgeComingSoon: "Wkrótce",
            .badgeAvailableIn: "Dostępne w planie {detail}",
            .badgeUpgrade: "Zmień plan",
            .couldNotConfirmAccess: "Nie udało się potwierdzić Twojego dostępu. Spróbuj ponownie.",
            .storeNotConfiguredContactSupport: "Sklep nie został jeszcze skonfigurowany. Skontaktuj się z pomocą techniczną.",
            .signInIncomplete: "Logowanie nie zostało dokończone. Spróbuj ponownie.",
            .somethingWentWrong: "Coś poszło nie tak. Spróbuj ponownie.",
            .connectionProblem: "Nie udało się połączyć. Sprawdź połączenie z internetem i spróbuj ponownie.",
            .callbackUnexpectedHost: "Adres powrotu z logowania ma nieoczekiwanego hosta",
            .callbackMissingCode: "W adresie powrotu z logowania brakuje kodu",
            .signInWindowLostConnection: "Okno logowania utraciło połączenie. Spróbuj ponownie.",
            .enterEmailAndPassword: "Podaj adres e-mail i hasło.",
            .passwordsDoNotMatch: "Hasła nie są takie same.",
            .passwordTooShort: "Hasło musi mieć co najmniej 8 znaków.",
            .enterEmail: "Podaj adres e-mail.",
            .errorNotAuthenticated: "Użytkownik nie jest zalogowany",
            .errorInvalidResponse: "Nieprawidłowa odpowiedź serwera",
            .errorNetwork: "Błąd sieci: {detail}",
            .errorCancelled: "Logowanie zostało anulowane",
            .errorTimeout: "Przekroczono czas oczekiwania: {detail}",
            .errorStoreNotConfigured: "Sklep tej aplikacji nie został jeszcze skonfigurowany.",
            .errorInAppStoreNotAllowed: "W tej aplikacji nie można kupić planu. Kupujący kupują w przeglądarce i logują się tutaj.",
            .errorSessionEnded: "Twoja sesja się zakończyła — zaloguj się ponownie",
            .errorUserRevoked: "To konto użytkownika zostało zawieszone",
            .errorNoActivePlan: "Brak aktywnej subskrypcji — plan wygasł lub został anulowany.",
            .errorVerificationRateLimited: "Najwyżej 3 e-maile weryfikacyjne na godzinę — spróbuj później",
            .errorInvalidVerificationToken: "Ten link weryfikacyjny jest nieprawidłowy, został już użyty, zastąpiony nowszym albo wygasł",
        ],
        "de": [
            .close: "Schließen",
            .signIn: "Anmelden",
            .useDifferentMethod: "Andere Methode verwenden",
            .signingYouIn: "Sie werden angemeldet…",
            .sendFeedback: "Feedback senden",
            .manageAccount: "Konto verwalten",
            .tryAgain: "Erneut versuchen",
            .couldNotLoadFeedback: "Feedback konnte nicht geladen werden",
            .badgeNew: "Neu",
            .badgeBeta: "Beta",
            .badgeComingSoon: "Demnächst verfügbar",
            .badgeAvailableIn: "Verfügbar im Plan {detail}",
            .badgeUpgrade: "Plan ändern",
            .couldNotConfirmAccess: "Ihr Zugang konnte nicht bestätigt werden. Bitte versuchen Sie es erneut.",
            .storeNotConfiguredContactSupport: "Der Shop ist noch nicht eingerichtet. Bitte wenden Sie sich an den Support.",
            .signInIncomplete: "Die Anmeldung wurde nicht abgeschlossen. Bitte versuchen Sie es erneut.",
            .somethingWentWrong: "Etwas ist schiefgelaufen. Bitte versuchen Sie es erneut.",
            .connectionProblem: "Keine Verbindung möglich. Bitte prüfen Sie Ihre Internetverbindung und versuchen Sie es erneut.",
            .callbackUnexpectedHost: "Die Rückleitungsadresse der Anmeldung hat einen unerwarteten Host",
            .callbackMissingCode: "In der Rückleitungsadresse der Anmeldung fehlt der Code",
            .signInWindowLostConnection: "Das Anmeldefenster hat die Verbindung verloren. Bitte versuchen Sie es erneut.",
            .enterEmailAndPassword: "Bitte geben Sie Ihre E-Mail-Adresse und Ihr Passwort ein.",
            .passwordsDoNotMatch: "Die Passwörter stimmen nicht überein.",
            .passwordTooShort: "Das Passwort muss mindestens 8 Zeichen lang sein.",
            .enterEmail: "Bitte geben Sie Ihre E-Mail-Adresse ein.",
            .errorNotAuthenticated: "Der Benutzer ist nicht angemeldet",
            .errorInvalidResponse: "Ungültige Antwort vom Server",
            .errorNetwork: "Netzwerkfehler: {detail}",
            .errorCancelled: "Die Anmeldung wurde abgebrochen",
            .errorTimeout: "Zeitüberschreitung: {detail}",
            .errorStoreNotConfigured: "Der Shop dieser App ist noch nicht eingerichtet.",
            .errorInAppStoreNotAllowed: "In dieser App können keine Pläne gekauft werden. Käufer kaufen im Web und melden sich hier an.",
            .errorSessionEnded: "Ihre Sitzung ist abgelaufen — bitte melden Sie sich erneut an",
            .errorUserRevoked: "Dieses Benutzerkonto wurde gesperrt",
            .errorNoActivePlan: "Kein aktives Abonnement — der Plan ist abgelaufen oder wurde gekündigt.",
            .errorVerificationRateLimited: "Höchstens 3 Bestätigungs-E-Mails pro Stunde — bitte versuchen Sie es später erneut",
            .errorInvalidVerificationToken: "Dieser Bestätigungslink ist ungültig, wurde bereits verwendet, durch einen neueren ersetzt oder ist abgelaufen",
        ],
        "fr": [
            .close: "Fermer",
            .signIn: "Se connecter",
            .useDifferentMethod: "Utiliser une autre méthode",
            .signingYouIn: "Connexion en cours…",
            .sendFeedback: "Envoyer un avis",
            .manageAccount: "Gérer le compte",
            .tryAgain: "Réessayer",
            .couldNotLoadFeedback: "Impossible de charger le formulaire d’avis",
            .badgeNew: "Nouveau",
            .badgeBeta: "Bêta",
            .badgeComingSoon: "Bientôt disponible",
            .badgeAvailableIn: "Disponible avec le plan {detail}",
            .badgeUpgrade: "Changer de plan",
            .couldNotConfirmAccess: "Impossible de confirmer votre accès. Veuillez réessayer.",
            .storeNotConfiguredContactSupport: "La boutique n’est pas encore configurée. Veuillez contacter l’assistance.",
            .signInIncomplete: "La connexion n’a pas abouti. Veuillez réessayer.",
            .somethingWentWrong: "Une erreur s’est produite. Veuillez réessayer.",
            .connectionProblem: "Connexion impossible. Vérifiez votre connexion Internet et réessayez.",
            .callbackUnexpectedHost: "L’adresse de retour de la connexion a un hôte inattendu",
            .callbackMissingCode: "Le code manque dans l’adresse de retour de la connexion",
            .signInWindowLostConnection: "La fenêtre de connexion a perdu la connexion. Veuillez réessayer.",
            .enterEmailAndPassword: "Veuillez saisir votre adresse e-mail et votre mot de passe.",
            .passwordsDoNotMatch: "Les mots de passe ne correspondent pas.",
            .passwordTooShort: "Le mot de passe doit contenir au moins 8 caractères.",
            .enterEmail: "Veuillez saisir votre adresse e-mail.",
            .errorNotAuthenticated: "L’utilisateur n’est pas connecté",
            .errorInvalidResponse: "Réponse du serveur non valide",
            .errorNetwork: "Erreur réseau : {detail}",
            .errorCancelled: "La connexion a été annulée",
            .errorTimeout: "Délai dépassé : {detail}",
            .errorStoreNotConfigured: "La boutique de cette application n’est pas encore configurée.",
            .errorInAppStoreNotAllowed: "Aucun forfait ne peut être acheté dans cette application. Les acheteurs achètent sur le web et se connectent ici.",
            .errorSessionEnded: "Votre session a pris fin — veuillez vous reconnecter",
            .errorUserRevoked: "Ce compte utilisateur a été suspendu",
            .errorNoActivePlan: "Aucun abonnement actif — le forfait a expiré ou a été résilié.",
            .errorVerificationRateLimited: "3 e-mails de vérification par heure au maximum — réessayez plus tard",
            .errorInvalidVerificationToken: "Ce lien de vérification n’est pas valide, a déjà été utilisé, a été remplacé par un plus récent ou a expiré",
        ],
        "es": [
            .close: "Cerrar",
            .signIn: "Iniciar sesión",
            .useDifferentMethod: "Usar otro método",
            .signingYouIn: "Iniciando sesión…",
            .sendFeedback: "Enviar comentarios",
            .manageAccount: "Gestionar la cuenta",
            .tryAgain: "Reintentar",
            .couldNotLoadFeedback: "No se han podido cargar los comentarios",
            .badgeNew: "Nuevo",
            .badgeBeta: "Beta",
            .badgeComingSoon: "Próximamente",
            .badgeAvailableIn: "Disponible en el plan {detail}",
            .badgeUpgrade: "Cambiar plan",
            .couldNotConfirmAccess: "No hemos podido confirmar tu acceso. Inténtalo de nuevo.",
            .storeNotConfiguredContactSupport: "La tienda aún no está configurada. Ponte en contacto con el soporte.",
            .signInIncomplete: "El inicio de sesión no se ha completado. Inténtalo de nuevo.",
            .somethingWentWrong: "Algo ha salido mal. Inténtalo de nuevo.",
            .connectionProblem: "No se ha podido conectar. Comprueba tu conexión a internet e inténtalo de nuevo.",
            .callbackUnexpectedHost: "La dirección de retorno del inicio de sesión tiene un host inesperado",
            .callbackMissingCode: "Falta el código en la dirección de retorno del inicio de sesión",
            .signInWindowLostConnection: "La ventana de inicio de sesión ha perdido la conexión. Inténtalo de nuevo.",
            .enterEmailAndPassword: "Introduce tu correo electrónico y tu contraseña.",
            .passwordsDoNotMatch: "Las contraseñas no coinciden.",
            .passwordTooShort: "La contraseña debe tener al menos 8 caracteres.",
            .enterEmail: "Introduce tu dirección de correo electrónico.",
            .errorNotAuthenticated: "El usuario no ha iniciado sesión",
            .errorInvalidResponse: "Respuesta del servidor no válida",
            .errorNetwork: "Error de red: {detail}",
            .errorCancelled: "Se ha cancelado el inicio de sesión",
            .errorTimeout: "Tiempo de espera agotado: {detail}",
            .errorStoreNotConfigured: "La tienda de esta aplicación aún no está configurada.",
            .errorInAppStoreNotAllowed: "No se pueden comprar planes dentro de esta aplicación. Los compradores compran en la web e inician sesión aquí.",
            .errorSessionEnded: "Tu sesión ha terminado — vuelve a iniciar sesión",
            .errorUserRevoked: "Esta cuenta de usuario ha sido suspendida",
            .errorNoActivePlan: "No hay ninguna suscripción activa — el plan ha caducado o se ha cancelado.",
            .errorVerificationRateLimited: "Como máximo 3 correos de verificación por hora — inténtalo más tarde",
            .errorInvalidVerificationToken: "Este enlace de verificación no es válido, ya se ha usado, se ha sustituido por uno más reciente o ha caducado",
        ],
        "it": [
            .close: "Chiudi",
            .signIn: "Accedi",
            .useDifferentMethod: "Usa un altro metodo",
            .signingYouIn: "Accesso in corso…",
            .sendFeedback: "Invia feedback",
            .manageAccount: "Gestisci account",
            .tryAgain: "Riprova",
            .couldNotLoadFeedback: "Impossibile caricare il feedback",
            .badgeNew: "Novità",
            .badgeBeta: "Beta",
            .badgeComingSoon: "Prossimamente",
            .badgeAvailableIn: "Disponibile nel piano {detail}",
            .badgeUpgrade: "Cambia piano",
            .couldNotConfirmAccess: "Non è stato possibile confermare il tuo accesso. Riprova.",
            .storeNotConfiguredContactSupport: "Lo store non è ancora configurato. Contatta l’assistenza.",
            .signInIncomplete: "L’accesso non è stato completato. Riprova.",
            .somethingWentWrong: "Si è verificato un problema. Riprova.",
            .connectionProblem: "Impossibile connettersi. Controlla la connessione a internet e riprova.",
            .callbackUnexpectedHost: "L’indirizzo di ritorno dell’accesso ha un host inatteso",
            .callbackMissingCode: "Nell’indirizzo di ritorno dell’accesso manca il codice",
            .signInWindowLostConnection: "La finestra di accesso ha perso la connessione. Riprova.",
            .enterEmailAndPassword: "Inserisci la tua e-mail e la password.",
            .passwordsDoNotMatch: "Le password non coincidono.",
            .passwordTooShort: "La password deve contenere almeno 8 caratteri.",
            .enterEmail: "Inserisci il tuo indirizzo e-mail.",
            .errorNotAuthenticated: "L’utente non ha effettuato l’accesso",
            .errorInvalidResponse: "Risposta del server non valida",
            .errorNetwork: "Errore di rete: {detail}",
            .errorCancelled: "L’accesso è stato annullato",
            .errorTimeout: "Tempo scaduto: {detail}",
            .errorStoreNotConfigured: "Lo store di questa app non è ancora configurato.",
            .errorInAppStoreNotAllowed: "In questa app non è possibile acquistare piani. Gli acquirenti acquistano sul web e accedono qui.",
            .errorSessionEnded: "La tua sessione è terminata — accedi di nuovo",
            .errorUserRevoked: "Questo account utente è stato sospeso",
            .errorNoActivePlan: "Nessun abbonamento attivo — il piano è scaduto o è stato annullato.",
            .errorVerificationRateLimited: "Al massimo 3 e-mail di verifica all’ora — riprova più tardi",
            .errorInvalidVerificationToken: "Questo link di verifica non è valido, è già stato usato, è stato sostituito da uno più recente o è scaduto",
        ],
        "pt": [
            .close: "Fechar",
            .signIn: "Iniciar sessão",
            .useDifferentMethod: "Utilizar outro método",
            .signingYouIn: "A iniciar sessão…",
            .sendFeedback: "Enviar feedback",
            .manageAccount: "Gerir conta",
            .tryAgain: "Tentar novamente",
            .couldNotLoadFeedback: "Não foi possível carregar o feedback",
            .badgeNew: "Novo",
            .badgeBeta: "Beta",
            .badgeComingSoon: "Brevemente",
            .badgeAvailableIn: "Disponível no plano {detail}",
            .badgeUpgrade: "Mudar de plano",
            .couldNotConfirmAccess: "Não foi possível confirmar o seu acesso. Tente novamente.",
            .storeNotConfiguredContactSupport: "A loja ainda não foi configurada. Contacte o apoio ao cliente.",
            .signInIncomplete: "O início de sessão não foi concluído. Tente novamente.",
            .somethingWentWrong: "Ocorreu um erro. Tente novamente.",
            .connectionProblem: "Não foi possível estabelecer ligação. Verifique a sua ligação à internet e tente novamente.",
            .callbackUnexpectedHost: "O endereço de retorno do início de sessão tem um anfitrião inesperado",
            .callbackMissingCode: "Falta o código no endereço de retorno do início de sessão",
            .signInWindowLostConnection: "A janela de início de sessão perdeu a ligação. Tente novamente.",
            .enterEmailAndPassword: "Introduza o seu e-mail e a palavra-passe.",
            .passwordsDoNotMatch: "As palavras-passe não coincidem.",
            .passwordTooShort: "A palavra-passe deve ter pelo menos 8 caracteres.",
            .enterEmail: "Introduza o seu endereço de e-mail.",
            .errorNotAuthenticated: "O utilizador não iniciou sessão",
            .errorInvalidResponse: "Resposta inválida do servidor",
            .errorNetwork: "Erro de rede: {detail}",
            .errorCancelled: "O início de sessão foi cancelado",
            .errorTimeout: "Tempo esgotado: {detail}",
            .errorStoreNotConfigured: "A loja desta aplicação ainda não foi configurada.",
            .errorInAppStoreNotAllowed: "Não é possível comprar planos nesta aplicação. Os compradores compram na web e iniciam sessão aqui.",
            .errorSessionEnded: "A sua sessão terminou — inicie sessão novamente",
            .errorUserRevoked: "Esta conta de utilizador foi suspensa",
            .errorNoActivePlan: "Nenhuma subscrição ativa — o plano expirou ou foi cancelado.",
            .errorVerificationRateLimited: "No máximo 3 e-mails de verificação por hora — tente mais tarde",
            .errorInvalidVerificationToken: "Este link de verificação é inválido, já foi utilizado, foi substituído por um mais recente ou expirou",
        ],
        "nl": [
            .close: "Sluiten",
            .signIn: "Inloggen",
            .useDifferentMethod: "Een andere methode gebruiken",
            .signingYouIn: "Je wordt ingelogd…",
            .sendFeedback: "Feedback versturen",
            .manageAccount: "Account beheren",
            .tryAgain: "Opnieuw proberen",
            .couldNotLoadFeedback: "Feedback kon niet worden geladen",
            .badgeNew: "Nieuw",
            .badgeBeta: "Bèta",
            .badgeComingSoon: "Binnenkort beschikbaar",
            .badgeAvailableIn: "Beschikbaar in het plan {detail}",
            .badgeUpgrade: "Plan wijzigen",
            .couldNotConfirmAccess: "We konden je toegang niet bevestigen. Probeer het opnieuw.",
            .storeNotConfiguredContactSupport: "De winkel is nog niet ingesteld. Neem contact op met de ondersteuning.",
            .signInIncomplete: "Inloggen is niet voltooid. Probeer het opnieuw.",
            .somethingWentWrong: "Er is iets misgegaan. Probeer het opnieuw.",
            .connectionProblem: "Kan geen verbinding maken. Controleer je internetverbinding en probeer het opnieuw.",
            .callbackUnexpectedHost: "Het terugkeeradres van het inloggen heeft een onverwachte host",
            .callbackMissingCode: "In het terugkeeradres van het inloggen ontbreekt de code",
            .signInWindowLostConnection: "Het inlogvenster heeft de verbinding verloren. Probeer het opnieuw.",
            .enterEmailAndPassword: "Vul je e-mailadres en wachtwoord in.",
            .passwordsDoNotMatch: "De wachtwoorden komen niet overeen.",
            .passwordTooShort: "Het wachtwoord moet minstens 8 tekens lang zijn.",
            .enterEmail: "Vul je e-mailadres in.",
            .errorNotAuthenticated: "De gebruiker is niet ingelogd",
            .errorInvalidResponse: "Ongeldig antwoord van de server",
            .errorNetwork: "Netwerkfout: {detail}",
            .errorCancelled: "Inloggen is geannuleerd",
            .errorTimeout: "Time-out: {detail}",
            .errorStoreNotConfigured: "De winkel van deze app is nog niet ingesteld.",
            .errorInAppStoreNotAllowed: "In deze app kunnen geen abonnementen worden gekocht. Kopers kopen op het web en loggen hier in.",
            .errorSessionEnded: "Je sessie is beëindigd — log opnieuw in",
            .errorUserRevoked: "Dit gebruikersaccount is opgeschort",
            .errorNoActivePlan: "Geen actief abonnement — het abonnement is verlopen of opgezegd.",
            .errorVerificationRateLimited: "Maximaal 3 verificatie-e-mails per uur — probeer het later opnieuw",
            .errorInvalidVerificationToken: "Deze verificatielink is ongeldig, al gebruikt, vervangen door een nieuwere of verlopen",
        ],
    ]
}

private let _textsLog = Logger(subsystem: "com.onelo.sdk", category: "texts")

/// #1074 — what an App User is shown for `error` on an SDK screen (the
/// sign-in/store retry screen, the portal, the feedback window). An
/// `OneloError` meant for them speaks the Page Language; a connection failure
/// says so; anything else — a server's own message, a developer-facing
/// configuration error — becomes "Something went wrong", in the Page
/// Language. The raw error is logged for the developer under `context`.
func oneloAppUserMessage(for error: Error, context: String) -> String {
    _textsLog.error("[\(context, privacy: .public)] \(String(describing: error), privacy: .public)")
    if let onelo = error as? OneloError {
        switch onelo {
        case .serverError, .invalidResponse, .invalidPublishableKey, .keychainError,
             .requiresHostedFlow, .emailVerificationOff, .invalidVerifyRedirect:
            return OneloText.somethingWentWrong.text
        case .networkError, .timeout:
            return OneloText.connectionProblem.text
        case .notAuthenticated, .cancelled, .storeNotConfigured, .inAppStoreNotAllowed, .sessionEnded,
             .userRevoked, .noActivePlan, .verificationRateLimited, .invalidVerificationToken:
            return onelo.errorDescription ?? OneloText.somethingWentWrong.text
        }
    }
    if (error as NSError).domain == NSURLErrorDomain {
        return OneloText.connectionProblem.text
    }
    return OneloText.somethingWentWrong.text
}
