{{- define "spendwise.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "spendwise.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ include "spendwise.imageTag" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* Selector labels for one component: include "spendwise.selectorLabels" (dict "ctx" . "component" "backend") */}}
{{- define "spendwise.selectorLabels" -}}
app.kubernetes.io/name: {{ .ctx.Chart.Name }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "spendwise.imageTag" -}}
{{- .Values.global.imageTag | default .Chart.AppVersion -}}
{{- end -}}

{{- define "spendwise.image" -}}
{{- printf "%s/%s:%s" .ctx.Values.global.imageRegistry .image.repository (include "spendwise.imageTag" .ctx) -}}
{{- end -}}

{{- define "spendwise.postgresHost" -}}
{{- printf "%s-postgres" (include "spendwise.fullname" .) -}}
{{- end -}}

{{- define "spendwise.secretName" -}}
{{- printf "%s-db" (include "spendwise.fullname" .) -}}
{{- end -}}

{{- define "spendwise.postgresPassword" -}}
{{- .Values.postgresql.auth.password | default "spendwise-dev-password" -}}
{{- end -}}
