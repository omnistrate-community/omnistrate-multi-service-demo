{{/* Standard name helpers. */}}

{{- define "ai-worker.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ai-worker.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "ai-worker.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Selector labels, the immutable subset. .Values.podLabels is not merged in here,
since spec.selector.matchLabels cannot change after create and folding them in
would break adding the billing label to a running release.
*/}}
{{- define "ai-worker.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ai-worker.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "ai-worker.labels" -}}
helm.sh/chart: {{ include "ai-worker.chart" . }}
{{ include "ai-worker.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: worker
app.kubernetes.io/part-of: durable-ai-platform
{{- end -}}

{{- define "ai-worker.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "ai-worker.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Secret holding every credential, so none reaches the ConfigMap. */}}
{{- define "ai-worker.secretName" -}}
{{- printf "%s-secrets" (include "ai-worker.fullname" .) -}}
{{- end -}}
